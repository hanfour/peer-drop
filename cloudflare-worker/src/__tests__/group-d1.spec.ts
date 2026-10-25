// Group chat room D1 schema (project G1a, Task 1): 0005_groups.sql adds
// group_members / group_invites and rebuilds `reports` so a group message can
// be reported by an account OR a device-only (anonymous) reporter.
import { SELF, env } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrationsThrough, applyMigrationFile } from "./d1";

const db = () => env.ACCOUNTS_DB;
const OLD_COLS = ["id", "reporter_account_id", "sender_hash", "inbox_item_id", "diary_id", "diary_seq", "reason", "excerpt", "created_at"];

let before: Record<string, unknown>[];

beforeAll(async () => {
  await applyMigrationsThrough(db(), "0004_account_settings.sql");
  await db().prepare("INSERT INTO reports (id, reporter_account_id, sender_hash, inbox_item_id, diary_id, diary_seq, reason, excerpt, created_at) VALUES ('n1','acct-a','hash-n','item-1',NULL,NULL,'spam','ex-n',100)").run();
  await db().prepare("INSERT INTO reports (id, reporter_account_id, sender_hash, inbox_item_id, diary_id, diary_seq, reason, excerpt, created_at) VALUES ('d1','acct-b','hash-d',NULL,'diary-1',7,'abuse',NULL,200)").run();
  before = (await db().prepare("SELECT * FROM reports ORDER BY id").all<Record<string, unknown>>()).results;
  await applyMigrationFile(db(), "0005_groups.sql");
});

async function insertReport(o: { id: string; acct: string | null; dev: string | null; groupId?: string | null; groupSeq?: number | null }) {
  await db().prepare("INSERT INTO reports (id, reporter_account_id, reporter_device_id, group_id, group_seq, reason, created_at) VALUES (?1, ?2, ?3, ?4, ?5, 'spam', 300)")
    .bind(o.id, o.acct, o.dev, o.groupId ?? null, o.groupSeq ?? null).run();
}

describe("0005_groups.sql", () => {
  it("0005 preserves every existing notes and diary report row", async () => {
    const after = (await db().prepare("SELECT * FROM reports WHERE id IN ('n1','d1') ORDER BY id").all<Record<string, unknown>>()).results;
    expect(after.length).toBe(2);
    for (let i = 0; i < 2; i++) {
      for (const c of OLD_COLS) expect(after[i][c]).toEqual(before[i][c]);
      expect(after[i].reporter_device_id).toBeNull();
      expect(after[i].group_id).toBeNull();
      expect(after[i].group_seq).toBeNull();
    }
  });

  it("reports accept a device-only reporter with group_id/group_seq", async () => {
    await insertReport({ id: "g1", acct: null, dev: "dev-x", groupId: "grp-1", groupSeq: 5 });
    const row = await db().prepare("SELECT * FROM reports WHERE id='g1'").first<Record<string, unknown>>();
    expect(row?.reporter_account_id).toBeNull();
    expect(row?.reporter_device_id).toBe("dev-x");
    expect(row?.group_id).toBe("grp-1");
    expect(row?.group_seq).toBe(5);
  });

  it("reports reject a row with neither reporter", async () => {
    await expect(insertReport({ id: "bad", acct: null, dev: null })).rejects.toThrow();
  });

  it("group_members/group_invites exist with their keys", async () => {
    await db().prepare("INSERT INTO group_members (account_id, group_id, joined_at) VALUES ('a','g',1)").run();
    await expect(db().prepare("INSERT INTO group_members (account_id, group_id, joined_at) VALUES ('a','g',2)").run()).rejects.toThrow();
    await db().prepare("INSERT INTO group_invites (invite_code, group_id) VALUES ('code1','g')").run();
    await expect(db().prepare("INSERT INTO group_invites (invite_code, group_id) VALUES ('code1','g2')").run()).rejects.toThrow();
    const names = async (t: string) => (await db().prepare(`PRAGMA index_list(${t})`).all<{ name: string }>()).results.map((r) => r.name);
    expect(await names("group_members")).toContain("group_members_group");
    expect(await names("group_invites")).toContain("group_invites_group");
    expect(await names("reports")).toEqual(expect.arrayContaining(["reports_sender", "reports_group"]));
  });

  it("admin reports exposes reporterDeviceId/groupId/groupSeq", async () => {
    const r = await SELF.fetch("https://example.com/v3/admin/reports?since=0", { headers: { "X-API-Key": "test-analytics-key-67890" } });
    expect(r.status).toBe(200);
    const { reports } = await r.json() as { reports: Record<string, unknown>[] };
    const g = reports.find((x) => x.id === "g1")!;
    expect(g.reporterAccountId).toBeNull();
    expect(g.reporterDeviceId).toBe("dev-x");
    expect(g.groupId).toBe("grp-1");
    expect(g.groupSeq).toBe(5);
    const n = reports.find((x) => x.id === "n1")!;
    expect(n.reporterDeviceId).toBeNull();
    expect(n.groupId).toBeNull();
  });
});
