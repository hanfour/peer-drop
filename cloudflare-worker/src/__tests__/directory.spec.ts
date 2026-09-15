import { env, SELF } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { registerDevice } from "./accountHelpers";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

describe("/v3/directory", () => {
  it("resolves by normalized id and by nickname; 404 otherwise", async () => {
    const a = await registerDevice("dev-dir-0000001");
    const { accountId, token } = await a.reg.json() as { accountId: string; token: string };
    await SELF.fetch("https://example.com/v3/account/nickname", { method: "PUT", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify({ nickname: "Dir_Owner" }) });
    const b = await registerDevice("dev-dir-0000002");
    const tb = (await b.reg.json() as { token: string }).token;
    const dashed = `${accountId.slice(0, 4)}-${accountId.slice(4).toLowerCase()}`;
    const r1 = await SELF.fetch(`https://example.com/v3/directory/${dashed}`, { headers: { Authorization: `Bearer ${tb}` } });
    expect(r1.status).toBe(200);
    const e1 = await r1.json() as { accountId: string; nickname: string; mailboxId: string; signingKey: string; preKeyBundle?: unknown };
    expect(e1.accountId).toBe(accountId);
    expect(e1.nickname).toBe("Dir_Owner");
    // registerDevice's fixture mailboxId is `mbx${deviceId.replace(/-/g, "")}`
    // (Task 4's fix round — the validator is strict ^[a-z0-9]{1,64}$, so the
    // hyphenated form the brief text describes was never valid).
    expect(e1.mailboxId).toBe("mbxdevdir0000001");
    expect(e1.preKeyBundle).toBeUndefined();
    const r2 = await SELF.fetch("https://example.com/v3/directory/dir_owner", { headers: { Authorization: `Bearer ${tb}` } });
    expect((await r2.json() as { accountId: string }).accountId).toBe(accountId);
    expect((await SELF.fetch("https://example.com/v3/directory/nobody_here", { headers: { Authorization: `Bearer ${tb}` } })).status).toBe(404);
  });

  it("bundle=1 returns the pre-key bundle when the mailbox has keys", async () => {
    const a = await registerDevice("dev-dir-0000003");
    const { accountId } = await a.reg.json() as { accountId: string };
    // Seed a pre-key bundle in KV the same shape /v2/keys/register writes
    // and the PreKeyStore DO's `fetch` reads back (index.ts: the
    // `keys:<mailboxId>` value is `JSON.stringify(preKeyBundle)`, where
    // preKeyBundle is `{identityKey, signingKey, signedPreKey, oneTimePreKeys}`;
    // consuming it returns `{identityKey, signingKey, signedPreKey, oneTimePreKey}`
    // with one shifted off oneTimePreKeys, singular, or null if none remain).
    await env.V2_STORE.put(`keys:mbxdevdir0000003`, JSON.stringify({ identityKey: "AA==", signingKey: "AA==", signedPreKey: { id: 1, publicKey: "AA==", signature: "AA==" }, oneTimePreKeys: [{ id: 7, publicKey: "AA==" }] }));
    const b = await registerDevice("dev-dir-0000004");
    const tb = (await b.reg.json() as { token: string }).token;
    const r = await SELF.fetch(`https://example.com/v3/directory/${accountId}?bundle=1`, { headers: { Authorization: `Bearer ${tb}` } });
    expect(r.status).toBe(200);
    const e = await r.json() as { preKeyBundle: { oneTimePreKey: { id: number } | null } };
    expect(e.preKeyBundle.oneTimePreKey?.id).toBe(7);
  });

  it("rate limits at 30 lookups per minute per account", async () => {
    const a = await registerDevice("dev-dir-0000005");
    const t = (await a.reg.json() as { token: string }).token;
    let last = 0;
    for (let i = 0; i < 31; i++) last = (await SELF.fetch("https://example.com/v3/directory/zzzzzzzz", { headers: { Authorization: `Bearer ${t}` } })).status;
    expect(last).toBe(429);
  });
});
