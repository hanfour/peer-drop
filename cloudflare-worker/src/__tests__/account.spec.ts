import { env, SELF } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { issueToken, freshTokenPayload } from "../deviceToken";
import { TEST_TOKEN_SECRET } from "./testSecrets";
import { scopeForDevice, accountIdFromScope } from "../account";

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
