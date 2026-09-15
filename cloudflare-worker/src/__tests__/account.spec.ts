import { env, SELF } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { issueToken, freshTokenPayload } from "../deviceToken";
import { TEST_TOKEN_SECRET } from "./testSecrets";
import { scopeForDevice, accountIdFromScope } from "../account";
import { buildSyntheticAssertion, toBase64 } from "./attestHelpers";
import { generateAccountId, normalizeAccountId, validateNickname, ACCOUNT_ID_ALPHABET, classifyRegisterError } from "../account";
import { registerDevice, ed25519Pair, b64, deviceToken, challengeAndSign } from "./accountHelpers";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

describe("account scope", () => {
  it("scopeForDevice is default for unbound devices and account:<id> for bound ones", async () => {
    expect(await scopeForDevice(env.ACCOUNTS_DB, "dev-unbound-1")).toBe("default");
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO accounts (account_id, signing_key, identity_key, mailbox_id, created_at, updated_at) VALUES ('SCOPE001', ?1, ?2, 'm', 0, 0)"
    ).bind(new Uint8Array([9, ...new Array(31).fill(0)]), new Uint8Array([8, ...new Array(31).fill(0)])).run();
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES ('SCOPE001', 'dev-bound-1', 'ios', 0)"
    ).run();
    expect(await scopeForDevice(env.ACCOUNTS_DB, "dev-bound-1")).toBe("account:SCOPE001");
    expect(accountIdFromScope("account:SCOPE001")).toBe("SCOPE001");
    expect(accountIdFromScope("default")).toBeNull();
  });
});

describe("/v3 gate", () => {
  it("rejects default-scope tokens, X-API-Key and ?token= on /v3/account/me", async () => {
    const def = await issueToken(freshTokenPayload("dev-bound-1", "default"), TEST_TOKEN_SECRET);
    expect((await SELF.fetch("https://example.com/v3/account/me", { headers: { Authorization: `Bearer ${def}` } })).status).toBe(401);
    expect((await SELF.fetch("https://example.com/v3/account/me", { headers: { "X-API-Key": "test-api-key-12345" } })).status).toBe(401);
    const acct = await issueToken(freshTokenPayload("dev-bound-1", "account:SCOPE001"), TEST_TOKEN_SECRET);
    expect((await SELF.fetch(`https://example.com/v3/account/me?token=${acct}`)).status).toBe(401);
  });
});

// --------------------------------------------------------------------------
// scopeForDevice must fail OPEN (to "default") on any D1 error — a D1
// outage, an unbound binding, or a migration that hasn't landed yet at
// deploy time must never turn into a hard failure for every device trying
// to attest/assert. See the doc comment on scopeForDevice in ../account.ts.
// --------------------------------------------------------------------------

describe("scopeForDevice fails open on D1 errors", () => {
  it("returns \"default\" when db.prepare throws", async () => {
    const brokenDb = { prepare() { throw new Error("boom"); } } as unknown as D1Database;
    expect(await scopeForDevice(brokenDb, "dev-broken-1")).toBe("default");
  });

  it("POST /v2/device/assert still issues a token (200) when account_devices is unusable", async () => {
    const TEAM_ID = "UK48R5KWLV";
    const BUNDLE_ID = "com.hanfour.peerdrop";
    const deviceId = "dev-d1-outage-1";

    const kp = (await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
    )) as CryptoKeyPair;
    const publicKeyDer = new Uint8Array(await crypto.subtle.exportKey("spki", kp.publicKey) as ArrayBuffer);
    await env.V2_STORE.put(`attest:${deviceId}`, JSON.stringify({
      keyId: "test-key-id",
      publicKeyDer: toBase64(publicKeyDer),
      receipt: "",
      counter: 0,
      attestedAt: Date.now(),
      bundleId: BUNDLE_ID,
    }));

    const clientData = new TextEncoder().encode("d1-outage-assert");
    const assertion = await buildSyntheticAssertion({
      teamId: TEAM_ID, bundleId: BUNDLE_ID, counter: 1, clientData, privateKey: kp.privateKey,
    });

    // Simulate a D1 outage/missing-table condition directly against the
    // real miniflare D1 binding (rather than mocking) — drop the table
    // scopeForDevice reads, drive the real route, then restore the schema
    // so later tests in this file aren't affected.
    await env.ACCOUNTS_DB.prepare("DROP TABLE account_devices").run();
    try {
      const resp = await SELF.fetch("https://example.com/v2/device/assert", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          deviceId,
          assertion: toBase64(assertion),
          clientData: toBase64(clientData),
        }),
      });
      expect(resp.status).toBe(200);
      const body = await resp.json() as { token?: string; expiresInSeconds?: number };
      expect(body.token).toBeTruthy();
    } finally {
      await applyMigrations(env.ACCOUNTS_DB);
    }
  });
});

describe("account id + nickname helpers", () => {
  it("generateAccountId yields 8 chars from the alphabet", () => {
    for (let i = 0; i < 50; i++) {
      const id = generateAccountId();
      expect(id).toHaveLength(8);
      for (const c of id) expect(ACCOUNT_ID_ALPHABET).toContain(c);
    }
  });
  it("normalizeAccountId strips, uppercases and maps confusables", () => {
    expect(normalizeAccountId("abcd-efgh")).toBe("ABCDEFGH");
    expect(normalizeAccountId(" 0o1i-lL2z ")).toBe("00111122".replace("22", "2Z"));
    expect(normalizeAccountId("ABCDEFG")).toBeNull();
    expect(normalizeAccountId("ABCDEFGU")).toBeNull();
  });
  it("validateNickname enforces length, charset, reserved words and NFC", () => {
    expect(validateNickname("mo")).toEqual({ ok: false, code: "invalid_nickname" });
    expect(validateNickname("a".repeat(21))).toEqual({ ok: false, code: "invalid_nickname" });
    expect(validateNickname("mo chi")).toEqual({ ok: false, code: "invalid_nickname" });
    expect(validateNickname("Admin")).toEqual({ ok: false, code: "reserved" });
    expect(validateNickname("麻糬_01")).toEqual({ ok: true, value: "麻糬_01" });
    expect(validateNickname("éclair")).toEqual({ ok: true, value: "éclair" });
  });
});

describe("/v3/account", () => {
  it("register creates an account and returns an account-scoped token", async () => {
    const { reg } = await registerDevice("dev-reg-000001");
    expect(reg.status).toBe(201);
    const body = await reg.json() as { accountId: string; nickname: string | null; token: string; expiresInSeconds: number };
    expect(body.accountId).toMatch(/^[0-9A-HJKMNP-TV-Z]{8}$/);
    expect(body.nickname).toBeNull();
    expect(body.expiresInSeconds).toBe(900);
    const me = await SELF.fetch("https://example.com/v3/account/me", { headers: { Authorization: `Bearer ${body.token}` } });
    expect(me.status).toBe(200);
    const meBody = await me.json() as { accountId: string; devices: { deviceId: string; platform: string }[] };
    expect(meBody.accountId).toBe(body.accountId);
    expect(meBody.devices).toEqual([{ deviceId: "dev-reg-000001", platform: "ios", boundAt: expect.any(Number) }]);
  });
  it("register rejects a reused nonce and a bad signature", async () => {
    const tok = await deviceToken("dev-reg-000002");
    const ch = await SELF.fetch("https://example.com/v3/account/challenge", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: "dev-reg-000002" }) });
    const { nonce } = await ch.json() as { nonce: string };
    const { raw } = await ed25519Pair();
    const bad = await SELF.fetch("https://example.com/v3/account/register", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: "dev-reg-000002", platform: "ios", identityKey: b64(new Uint8Array(32)), signingKey: b64(raw), mailboxId: "m", nonce, signature: b64(new Uint8Array(64)) }) });
    expect(bad.status).toBe(400);
    expect((await bad.json() as { error: string }).error).toBe("bad_signature");
    const again = await SELF.fetch("https://example.com/v3/account/register", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: "dev-reg-000002", platform: "ios", identityKey: b64(new Uint8Array(32)), signingKey: b64(raw), mailboxId: "m", nonce, signature: b64(new Uint8Array(64)) }) });
    expect(again.status).toBe(400);
    expect((await again.json() as { error: string }).error).toBe("nonce_invalid");
  });
  it("same signing key from a second device binds to the existing account", async () => {
    const first = await registerDevice("dev-multi-00001", "ios");
    const a = (await first.reg.json() as { accountId: string }).accountId;
    const second = await registerDevice("dev-multi-00002", "macos", first.pair);
    expect(second.reg.status).toBe(201);
    expect((await second.reg.json() as { accountId: string }).accountId).toBe(a);
  });
  it("a device already bound to another account gets 409 device_bound, with no orphan account row for the losing signing key", async () => {
    const first = await registerDevice("dev-bound-00001");
    expect(first.reg.status).toBe(201);
    const other = await registerDevice("dev-bound-00001");  // fresh key pair, same device
    expect(other.reg.status).toBe(409);
    expect((await other.reg.json() as { error: string }).error).toBe("device_bound");
    // The rejected attempt's fresh signing key must not have left behind a
    // partially-created account row (atomic batch — see index.ts register route).
    const row = await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM accounts WHERE signing_key = ?1").bind(other.pair.raw).first<{ n: number }>();
    expect(row?.n).toBe(0);
  });
  it("registering a different device+key with an already-used identity key gets 409 identity_bound", async () => {
    const sharedIdentityKey = new Uint8Array(32);
    sharedIdentityKey.set([1, 2, 3, 4, 5], 0);

    const deviceA = "dev-ident-a-0001";
    const pairA = await ed25519Pair();
    const tokA = await deviceToken(deviceA);
    const { nonce: nonceA, signature: sigA } = await challengeAndSign(deviceA, tokA, pairA.kp.privateKey);
    const regA = await SELF.fetch("https://example.com/v3/account/register", {
      method: "POST", headers: { Authorization: `Bearer ${tokA}`, "Content-Type": "application/json" },
      body: JSON.stringify({ deviceId: deviceA, platform: "ios", identityKey: b64(sharedIdentityKey), signingKey: b64(pairA.raw), mailboxId: `mbx${deviceA.replace(/-/g, "")}`, nonce: nonceA, signature: sigA }),
    });
    expect(regA.status).toBe(201);

    const deviceB = "dev-ident-b-0002";
    const pairB = await ed25519Pair();
    const tokB = await deviceToken(deviceB);
    const { nonce: nonceB, signature: sigB } = await challengeAndSign(deviceB, tokB, pairB.kp.privateKey);
    const regB = await SELF.fetch("https://example.com/v3/account/register", {
      method: "POST", headers: { Authorization: `Bearer ${tokB}`, "Content-Type": "application/json" },
      body: JSON.stringify({ deviceId: deviceB, platform: "ios", identityKey: b64(sharedIdentityKey), signingKey: b64(pairB.raw), mailboxId: `mbx${deviceB.replace(/-/g, "")}`, nonce: nonceB, signature: sigB }),
    });
    expect(regB.status).toBe(409);
    expect((await regB.json() as { error: string }).error).toBe("identity_bound");
  });
  it("register requires the token deviceId to match the body", async () => {
    const tok = await deviceToken("dev-mismatch-001");
    const resp = await SELF.fetch("https://example.com/v3/account/challenge", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: "dev-mismatch-002" }) });
    expect(resp.status).toBe(403);
  });
  it("nickname set / conflict / clear / rate limit", async () => {
    const a = await registerDevice("dev-nick-000001");
    const b = await registerDevice("dev-nick-000002");
    const ta = (await a.reg.json() as { token: string }).token;
    const tb = (await b.reg.json() as { token: string }).token;
    const put = (t: string, nickname: string | null) => SELF.fetch("https://example.com/v3/account/nickname", { method: "PUT", headers: { Authorization: `Bearer ${t}`, "Content-Type": "application/json" }, body: JSON.stringify({ nickname }) });
    expect((await put(ta, "Mochi")).status).toBe(200);
    const taken = await put(tb, "mochi");
    expect(taken.status).toBe(409);
    expect((await taken.json() as { error: string }).error).toBe("nickname_taken");
    expect((await put(tb, "admin")).status).toBe(400);
    expect((await put(ta, null)).status).toBe(200);
    expect((await put(tb, "mochi")).status).toBe(200);  // released
    for (let i = 0; i < 3; i++) expect((await put(ta, `n${i}abc`)).status).toBe(200);  // ta: 2 used + 3 = 5
    expect((await put(ta, "over_limit")).status).toBe(429);
  });
  it("DELETE /v3/account removes the account and its devices", async () => {
    const a = await registerDevice("dev-del-0000001");
    const t = (await a.reg.json() as { token: string }).token;
    expect((await SELF.fetch("https://example.com/v3/account", { method: "DELETE", headers: { Authorization: `Bearer ${t}` } })).status).toBe(204);
    const row = await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM account_devices WHERE device_id = 'dev-del-0000001'").first<{ n: number }>();
    expect(row?.n).toBe(0);
  });
});

describe("classifyRegisterError", () => {
  it("classifies D1 UNIQUE constraint errors by which column tripped, and falls through to \"other\"", () => {
    expect(classifyRegisterError(new Error("D1_ERROR: UNIQUE constraint failed: accounts.account_id: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_UNIQUE)"))).toBe("account_id");
    expect(classifyRegisterError(new Error("D1_ERROR: UNIQUE constraint failed: accounts.identity_key: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_UNIQUE)"))).toBe("identity_bound");
    expect(classifyRegisterError(new Error("D1_ERROR: UNIQUE constraint failed: accounts.signing_key: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_UNIQUE)"))).toBe("signing_key");
    expect(classifyRegisterError(new Error("D1_ERROR: UNIQUE constraint failed: account_devices.device_id: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_UNIQUE)"))).toBe("device_bound");
    expect(classifyRegisterError(new Error("D1_ERROR: UNIQUE constraint failed: account_devices.account_id, account_devices.device_id: SQLITE_CONSTRAINT"))).toBe("device_bound");
    expect(classifyRegisterError(new Error("some unrelated D1 error"))).toBe("other");
    expect(classifyRegisterError("boom")).toBe("other");
    expect(classifyRegisterError({})).toBe("other");
  });
});
