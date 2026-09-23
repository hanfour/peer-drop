import { env } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";

describe("D1 accounts schema", () => {
  beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

  it("creates accounts and account_devices with the unique device index", async () => {
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO accounts (account_id, signing_key, identity_key, mailbox_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, 0, 0)"
    ).bind("ABCDEFGH", new Uint8Array(32), new Uint8Array([1, ...new Array(31).fill(0)]), "mbx").run();
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES ('ABCDEFGH', 'dev-1', 'ios', 0)"
    ).run();

    // Same account_id + device_id: rejected by the composite PRIMARY KEY
    // (account_id, device_id). Documents that constraint, but doesn't by
    // itself exercise the separate `account_devices_device` UNIQUE index
    // below (a duplicate PK collides before the index is even checked).
    const dupSameAccount = env.ACCOUNTS_DB.prepare(
      "INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES ('ABCDEFGH', 'dev-1', 'macos', 0)"
    ).run();
    await expect(dupSameAccount).rejects.toThrow();

    // A second, distinct account trying to claim the SAME device_id: the
    // composite PK allows this (different account_id), so only the
    // `account_devices_device` UNIQUE index on device_id alone can reject
    // it — this is the constraint the test is actually meant to cover.
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO accounts (account_id, signing_key, identity_key, mailbox_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, 0, 0)"
    ).bind("ABCDEFG2", new Uint8Array([6, ...new Array(31).fill(0)]), new Uint8Array([7, ...new Array(31).fill(0)]), "mbx2").run();
    const dupCrossAccount = env.ACCOUNTS_DB.prepare(
      "INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES ('ABCDEFG2', 'dev-1', 'macos', 0)"
    ).run();
    await expect(dupCrossAccount).rejects.toThrow();

    const row = await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM account_devices").first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("nickname uniqueness is case-insensitive", async () => {
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO accounts (account_id, signing_key, identity_key, nickname, mailbox_id, created_at, updated_at) VALUES ('AAAAAAA1', ?1, ?2, 'Mochi', 'm1', 0, 0)"
    ).bind(new Uint8Array([2, ...new Array(31).fill(0)]), new Uint8Array([3, ...new Array(31).fill(0)])).run();
    const dup = env.ACCOUNTS_DB.prepare(
      "INSERT INTO accounts (account_id, signing_key, identity_key, nickname, mailbox_id, created_at, updated_at) VALUES ('AAAAAAA2', ?1, ?2, 'mochi', 'm2', 0, 0)"
    ).bind(new Uint8Array([4, ...new Array(31).fill(0)]), new Uint8Array([5, ...new Array(31).fill(0)])).run();
    await expect(dup).rejects.toThrow();
  });
});
