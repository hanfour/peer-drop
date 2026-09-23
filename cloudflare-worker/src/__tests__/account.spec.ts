import { env, SELF } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { issueToken, freshTokenPayload } from "../deviceToken";
import { TEST_TOKEN_SECRET } from "./testSecrets";
import { scopeForDevice, accountIdFromScope } from "../account";
import { buildSyntheticAssertion, toBase64 } from "./attestHelpers";
import { generateAccountId, normalizeAccountId, validateNickname, ACCOUNT_ID_ALPHABET, classifyRegisterError } from "../account";
import { registerDevice, ed25519Pair, b64, deviceToken, challengeAndSign, seedMailbox, identityKeyForDevice, mailboxIdForDevice } from "./accountHelpers";
import { isKeyLane } from "../index";
import type { Env } from "../index";
import { TEST_API_KEY, TEST_MAC_CLIENT_KEY } from "./testSecrets";

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
    const mailboxToken = await seedMailbox("m");
    const ch = await SELF.fetch("https://example.com/v3/account/challenge", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: "dev-reg-000002" }) });
    const { nonce } = await ch.json() as { nonce: string };
    const { raw } = await ed25519Pair();
    const bad = await SELF.fetch("https://example.com/v3/account/register", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: "dev-reg-000002", platform: "ios", identityKey: b64(new Uint8Array(32)), signingKey: b64(raw), mailboxId: "m", mailboxToken, nonce, signature: b64(new Uint8Array(64)) }) });
    expect(bad.status).toBe(400);
    expect((await bad.json() as { error: string }).error).toBe("bad_signature");
    const again = await SELF.fetch("https://example.com/v3/account/register", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: "dev-reg-000002", platform: "ios", identityKey: b64(new Uint8Array(32)), signingKey: b64(raw), mailboxId: "m", mailboxToken, nonce, signature: b64(new Uint8Array(64)) }) });
    expect(again.status).toBe(400);
    expect((await again.json() as { error: string }).error).toBe("nonce_invalid");
  });
  it("register rejects malformed JSON and non-base64 key material", async () => {
    const deviceId = "dev-reg-000003";
    const tok = await deviceToken(deviceId);
    const badJson = await SELF.fetch("https://example.com/v3/account/register", {
      method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: "{not json",
    });
    expect(badJson.status).toBe(400);
    expect((await badJson.json() as { error: string }).error).toBe("invalid_json");

    // Every other field is well-formed, so the request reaches the decode
    // step and fails there rather than in the missing-fields guard.
    const mailboxId = mailboxIdForDevice(deviceId);
    const mailboxToken = await seedMailbox(mailboxId);
    const ch = await SELF.fetch("https://example.com/v3/account/challenge", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId }) });
    const { nonce } = await ch.json() as { nonce: string };
    const badB64 = await SELF.fetch("https://example.com/v3/account/register", {
      method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
      body: JSON.stringify({ deviceId, platform: "ios", identityKey: "not base64!!", signingKey: "also not base64!!", mailboxId, mailboxToken, nonce, signature: "###" }),
    });
    expect(badB64.status).toBe(400);
    expect((await badB64.json() as { error: string }).error).toBe("invalid_encoding");
  });
  it("register refuses a mailbox the caller cannot prove it owns", async () => {
    const deviceId = "dev-mbx-0000001";
    const pair = await ed25519Pair();
    const tok = await deviceToken(deviceId);
    const identityKey = await identityKeyForDevice(deviceId);

    // (a) mailbox that was never registered → no meta in KV at all.
    const ghost = "mbxghostmailbox";
    const sigGhost = await challengeAndSign(deviceId, tok, pair.kp.privateKey, identityKey, ghost);
    const respGhost = await SELF.fetch("https://example.com/v3/account/register", {
      method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
      body: JSON.stringify({ deviceId, platform: "ios", identityKey: b64(identityKey), signingKey: b64(pair.raw), mailboxId: ghost, mailboxToken: "whatever", nonce: sigGhost.nonce, signature: sigGhost.signature }),
    });
    expect(respGhost.status).toBe(403);
    expect((await respGhost.json() as { error: string }).error).toBe("mailbox_not_owned");

    // (b) somebody ELSE's mailbox, with the wrong token.
    const victim = "mbxvictimmailbox";
    await seedMailbox(victim);
    const sigVictim = await challengeAndSign(deviceId, tok, pair.kp.privateKey, identityKey, victim);
    const respVictim = await SELF.fetch("https://example.com/v3/account/register", {
      method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
      body: JSON.stringify({ deviceId, platform: "ios", identityKey: b64(identityKey), signingKey: b64(pair.raw), mailboxId: victim, mailboxToken: "0".repeat(64), nonce: sigVictim.nonce, signature: sigVictim.signature }),
    });
    expect(respVictim.status).toBe(403);
    expect((await respVictim.json() as { error: string }).error).toBe("mailbox_not_owned");
  });
  it("a signature made for one mailbox does not authorize another", async () => {
    const deviceId = "dev-mbx-0000002";
    const pair = await ed25519Pair();
    const tok = await deviceToken(deviceId);
    const identityKey = await identityKeyForDevice(deviceId);
    const mine = mailboxIdForDevice(deviceId);
    await seedMailbox(mine);
    const other = "mbxotherowned01";
    const otherToken = await seedMailbox(other);
    // Signed over `mine`, submitted for `other` (whose token the caller
    // does hold) — the v2 message binds the mailbox id, so this is a
    // signature failure, not a successful mailbox swap.
    const { nonce, signature } = await challengeAndSign(deviceId, tok, pair.kp.privateKey, identityKey, mine);
    const resp = await SELF.fetch("https://example.com/v3/account/register", {
      method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
      body: JSON.stringify({ deviceId, platform: "ios", identityKey: b64(identityKey), signingKey: b64(pair.raw), mailboxId: other, mailboxToken: otherToken, nonce, signature }),
    });
    expect(resp.status).toBe(400);
    expect((await resp.json() as { error: string }).error).toBe("bad_signature");
  });
  it("re-registering the same signing key with a new identity key updates the directory", async () => {
    const first = await registerDevice("dev-idrot-00001");
    expect(first.reg.status).toBe(201);
    const { accountId, token } = await first.reg.json() as { accountId: string; token: string };

    // Same device, same signing key (survives a reinstall in Keychain),
    // but a regenerated X25519 identity key.
    const freshIdentity = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("identity:dev-idrot-00001:v2")));
    const second = await registerDevice("dev-idrot-00001", "ios", first.pair, { identityKey: freshIdentity });
    expect(second.reg.status).toBe(201);
    expect((await second.reg.json() as { accountId: string }).accountId).toBe(accountId);

    const dir = await SELF.fetch(`https://example.com/v3/directory/${accountId}`, { headers: { Authorization: `Bearer ${token}` } });
    expect(dir.status).toBe(200);
    expect((await dir.json() as { identityKey: string }).identityKey).toBe(b64(freshIdentity));
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

    const regA = await registerDevice("dev-ident-a-0001", "ios", undefined, { identityKey: sharedIdentityKey });
    expect(regA.reg.status).toBe(201);

    const regB = await registerDevice("dev-ident-b-0002", "ios", undefined, { identityKey: sharedIdentityKey });
    expect(regB.reg.status).toBe(409);
    expect((await regB.reg.json() as { error: string }).error).toBe("identity_bound");
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

// --------------------------------------------------------------------------
// POST /v2/keys/register — re-registering an existing mailbox requires the
// mailbox token. Before 2026-09-15 an omitted `token` skipped the check
// entirely, so anyone who knew a mailbox id could overwrite its pre-key
// bundle (a silent key-substitution attack on every future sender).
// --------------------------------------------------------------------------

describe("/v2/keys/register ownership", () => {
  const bundle = { identityKey: "AA==", signingKey: "AA==", signedPreKey: { id: 1, publicKey: "AA==", signature: "AA==" }, oneTimePreKeys: [] };
  const post = (body: unknown) => SELF.fetch("https://example.com/v2/keys/register", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });

  it("creates a brand-new mailbox without a token and returns one", async () => {
    const resp = await post({ mailboxId: "mbxfirstwriter01", preKeyBundle: bundle });
    expect(resp.status).toBe(201);
    expect((await resp.json() as { token: string }).token).toMatch(/^[0-9a-f]{64}$/);
  });

  it("rejects re-registration with no token (403) and with a wrong token (403)", async () => {
    const first = await post({ mailboxId: "mbxownedmailbox1", preKeyBundle: bundle });
    expect(first.status).toBe(201);
    const token = (await first.json() as { token: string }).token;

    const noToken = await post({ mailboxId: "mbxownedmailbox1", preKeyBundle: { ...bundle, identityKey: "Ag==" } });
    expect(noToken.status).toBe(403);
    expect((await noToken.json() as { error: string }).error).toBe("forbidden");

    const wrongToken = await post({ mailboxId: "mbxownedmailbox1", preKeyBundle: { ...bundle, identityKey: "Ag==" }, token: "0".repeat(64) });
    expect(wrongToken.status).toBe(403);

    // The bundle is untouched by the two rejected writes.
    expect(JSON.parse((await env.V2_STORE.get("keys:mbxownedmailbox1"))!).identityKey).toBe("AA==");

    const ok = await post({ mailboxId: "mbxownedmailbox1", preKeyBundle: { ...bundle, identityKey: "Ag==" }, token });
    expect(ok.status).toBe(201);
    expect(JSON.parse((await env.V2_STORE.get("keys:mbxownedmailbox1"))!).identityKey).toBe("Ag==");
  });
});

// --------------------------------------------------------------------------
// The /v3 key lane: `X-API-Key` + `X-Device-Id` for surfaces without App
// Attest (peerdrop-cli, native macOS — DCAppAttestService.isSupported is
// false there, verified 2026-09-15). Read/registration routes only.
// --------------------------------------------------------------------------

describe("/v3 key lane", () => {
  const keyHeaders = (deviceId: string) => ({ "X-API-Key": TEST_API_KEY, "X-Device-Id": deviceId, "Content-Type": "application/json" });

  it("isKeyLane classifies both keys and falls back to API_KEY when MAC_CLIENT_KEY is unset", () => {
    const withBoth = { API_KEY: "op-key", MAC_CLIENT_KEY: "mac-key" } as unknown as Env;
    expect(isKeyLane("op-key", withBoth)).toBe("operator");
    expect(isKeyLane("mac-key", withBoth)).toBe("client");
    expect(isKeyLane("nope", withBoth)).toBeNull();
    expect(isKeyLane(null, withBoth)).toBeNull();
    const withoutMac = { API_KEY: "op-key" } as unknown as Env;
    expect(isKeyLane("op-key", withoutMac)).toBe("operator");
    expect(isKeyLane("mac-key", withoutMac)).toBeNull();
    // An unset API_KEY must never make the empty string a valid credential.
    expect(isKeyLane("", { API_KEY: "" } as unknown as Env)).toBeNull();
  });

  it("registers a Mac through the key lane and serves /v3/account/me for it", async () => {
    const deviceId = "dev-keylane-mac1";
    const pair = await ed25519Pair();
    const identityKey = await identityKeyForDevice(deviceId);
    const mailboxId = mailboxIdForDevice(deviceId);
    const mailboxToken = await seedMailbox(mailboxId);

    const ch = await SELF.fetch("https://example.com/v3/account/challenge", {
      method: "POST", headers: keyHeaders(deviceId), body: JSON.stringify({ deviceId }),
    });
    expect(ch.status).toBe(201);
    const { nonce } = await ch.json() as { nonce: string };
    const nonceBytes = Uint8Array.from(atob(nonce), (c) => c.charCodeAt(0));
    const bound = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array([...identityKey, ...new TextEncoder().encode(mailboxId)])));
    const msg = new Uint8Array([...new TextEncoder().encode("peerdrop-account-v2"), ...nonceBytes, ...new TextEncoder().encode(deviceId), ...bound]);
    const signature = b64(new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, pair.kp.privateKey, msg)));

    const reg = await SELF.fetch("https://example.com/v3/account/register", {
      method: "POST", headers: keyHeaders(deviceId),
      body: JSON.stringify({ deviceId, platform: "macos", identityKey: b64(identityKey), signingKey: b64(pair.raw), mailboxId, mailboxToken, nonce, signature }),
    });
    expect(reg.status).toBe(201);
    const { accountId, token } = await reg.json() as { accountId: string; token: string };

    const row = await env.ACCOUNTS_DB.prepare("SELECT account_id, platform FROM account_devices WHERE device_id = ?1").bind(deviceId).first<{ account_id: string; platform: string }>();
    expect(row).toEqual({ account_id: accountId, platform: "macos" });

    // /v3/account/me over the key lane resolves the scope from the device
    // binding (scopeForDevice), so it returns that same account.
    const me = await SELF.fetch("https://example.com/v3/account/me", { headers: keyHeaders(deviceId) });
    expect(me.status).toBe(200);
    expect((await me.json() as { accountId: string }).accountId).toBe(accountId);

    // Directory lookups are allowed on the key lane too.
    const dir = await SELF.fetch(`https://example.com/v3/directory/${accountId}`, { headers: keyHeaders(deviceId) });
    expect(dir.status).toBe(200);

    // …but the mutating routes are Bearer-only.
    const nick = await SELF.fetch("https://example.com/v3/account/nickname", { method: "PUT", headers: keyHeaders(deviceId), body: JSON.stringify({ nickname: "keylane" }) });
    expect(nick.status).toBe(401);
    expect((await nick.json() as { error: string }).error).toBe("bearer_required");
    const del = await SELF.fetch("https://example.com/v3/account", { method: "DELETE", headers: keyHeaders(deviceId) });
    expect(del.status).toBe(401);
    expect((await del.json() as { error: string }).error).toBe("bearer_required");

    // The Bearer minted by register still works for both.
    const nickOk = await SELF.fetch("https://example.com/v3/account/nickname", { method: "PUT", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify({ nickname: "keylane" }) });
    expect(nickOk.status).toBe(200);
  });

  it("refuses a key with no X-Device-Id, a key in the query string, and an unbound device id", async () => {
    const noDevice = await SELF.fetch("https://example.com/v3/account/me", { headers: { "X-API-Key": TEST_API_KEY } });
    expect(noDevice.status).toBe(401);

    const viaQuery = await SELF.fetch(`https://example.com/v3/account/me?apiKey=${TEST_API_KEY}`, { headers: { "X-Device-Id": "dev-keylane-mac1" } });
    expect(viaQuery.status).toBe(401);

    // Authenticated by the key, but the device is bound to no account →
    // "default" scope → authorizeV3 rejects it.
    const unbound = await SELF.fetch("https://example.com/v3/account/me", { headers: keyHeaders("dev-keylane-unbound") });
    expect(unbound.status).toBe(401);

    // A wrong key is rejected even with a bound device id.
    const wrongKey = await SELF.fetch("https://example.com/v3/account/me", { headers: { "X-API-Key": "definitely-wrong-key", "X-Device-Id": "dev-keylane-mac1" } });
    expect(wrongKey.status).toBe(401);

    // As is a malformed device id.
    const badDevice = await SELF.fetch("https://example.com/v3/account/me", { headers: { "X-API-Key": TEST_API_KEY, "X-Device-Id": "bad id!" } });
    expect(badDevice.status).toBe(401);
  });

  it("the Mac client key reaches the /v2 relay surfaces and the /v3 read lane, but not the mutating routes", async () => {
    // /v2: the shipped Mac has no App Attest, so its own key must open the
    // relay routes the operator key opens.
    const room = await SELF.fetch("https://example.com/room", { method: "POST", headers: { "X-API-Key": TEST_MAC_CLIENT_KEY } });
    expect(room.status).toBe(201);
    const ws = await SELF.fetch(`https://example.com/v2/inbox/device-macclient-1?apiKey=${TEST_MAC_CLIENT_KEY}`, { headers: { Upgrade: "websocket" } });
    expect(ws.status).toBe(101);
    ws.webSocket!.accept(); ws.webSocket!.close();

    // /v3: same restricted lane as the operator key (dev-keylane-mac1 was
    // registered by the test above).
    const clientHeaders = { "X-API-Key": TEST_MAC_CLIENT_KEY, "X-Device-Id": "dev-keylane-mac1", "Content-Type": "application/json" };
    const me = await SELF.fetch("https://example.com/v3/account/me", { headers: clientHeaders });
    expect(me.status).toBe(200);
    const nick = await SELF.fetch("https://example.com/v3/account/nickname", { method: "PUT", headers: clientHeaders, body: JSON.stringify({ nickname: "macclient" }) });
    expect(nick.status).toBe(401);
    expect((await nick.json() as { error: string }).error).toBe("bearer_required");
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
