import { env, SELF } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { issueToken, freshTokenPayload } from "../deviceToken";
import { TEST_TOKEN_SECRET } from "./testSecrets";
import { scopeForDevice, accountIdFromScope } from "../account";
import { buildSyntheticAssertion, toBase64 } from "./attestHelpers";

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
