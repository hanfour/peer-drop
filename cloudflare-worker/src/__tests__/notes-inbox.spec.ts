import { SELF, env } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { makeAccount, bearer, keyLane, sendNote, fakeEnvelope } from "./notesHelpers";
import { NOTE_LIMITS } from "../notes";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

const ANALYTICS_KEY = "test-analytics-key-67890";
type Inbox = { items: { id: string; kind: string; envelope: string; createdAt: number; readAt: number | null }[]; nextAfter?: string };
const inbox = async (h: Record<string, string>, q = ""): Promise<Inbox> => (await SELF.fetch(`https://example.com/v3/inbox${q}`, { headers: h })).json();

describe("/v3/inbox", () => {
  it("lists, pages, marks read and deletes (idempotent) — via bearer and the key lane", async () => {
    const a = await makeAccount("dev-note-inb-0001"), b = await makeAccount("dev-note-inb-0002", "macos");
    const ids: string[] = [];
    for (const s of [1, 2, 3]) ids.push(((await (await sendNote(bearer(a), b.accountId, fakeEnvelope(s))).json()) as { id: string }).id);
    const p1 = await inbox(keyLane(b), "?limit=2");
    expect(p1.items.map((i) => i.id)).toEqual(ids.slice(0, 2));
    expect(p1.items[0].kind).toBe("note");
    expect(p1.nextAfter).toBe(ids[1]);
    const p2 = await inbox(bearer(b), `?after=${p1.nextAfter}&limit=2`);
    expect(p2.items.map((i) => i.id)).toEqual([ids[2]]);
    expect(p2.nextAfter).toBeUndefined();
    expect((await SELF.fetch(`https://example.com/v3/inbox/${ids[0]}/read`, { method: "POST", headers: keyLane(b) })).status).toBe(204);
    expect(typeof (await inbox(bearer(b), "?limit=1")).items[0].readAt).toBe("number");
    expect((await SELF.fetch(`https://example.com/v3/inbox/${ids[0]}`, { method: "DELETE", headers: bearer(b) })).status).toBe(204);
    expect((await SELF.fetch(`https://example.com/v3/inbox/${ids[0]}`, { method: "DELETE", headers: bearer(b) })).status).toBe(204);
    expect((await inbox(bearer(b))).items.map((i) => i.id)).toEqual(ids.slice(1));
  });
  it("a caller only ever sees its own inbox", async () => {
    const a = await makeAccount("dev-note-inb-0003"), b = await makeAccount("dev-note-inb-0004"), c = await makeAccount("dev-note-inb-0005");
    const id = ((await (await sendNote(bearer(a), b.accountId)).json()) as { id: string }).id;
    expect((await inbox(bearer(c))).items).toEqual([]);
    // C deleting B's item id is a no-op on C's own (empty) inbox.
    expect((await SELF.fetch(`https://example.com/v3/inbox/${id}`, { method: "DELETE", headers: bearer(c) })).status).toBe(204);
    expect((await inbox(bearer(b))).items.length).toBe(1);
  });
});

describe("blocks", () => {
  it("block → later notes from that sender vanish silently; unblock → delivered again", async () => {
    const a = await makeAccount("dev-note-blk-0001"), b = await makeAccount("dev-note-blk-0002");
    const id = ((await (await sendNote(bearer(a), b.accountId)).json()) as { id: string }).id;
    const blk = await SELF.fetch(`https://example.com/v3/inbox/${id}/block`, { method: "POST", headers: bearer(b) });
    expect(blk.status).toBe(200);
    const { blocked } = await blk.json() as { blocked: string };
    expect(blocked).toMatch(/^[0-9a-f]{64}$/);
    expect((await inbox(bearer(b))).items.length).toBe(1); // the reported item itself stays
    expect((await sendNote(bearer(a), b.accountId, fakeEnvelope(2))).status).toBe(201);
    expect((await inbox(bearer(b))).items.length).toBe(1);
    const list = await (await SELF.fetch("https://example.com/v3/blocks", { headers: bearer(b) })).json() as { senderHash: string; createdAt: number }[];
    expect(list.map((x) => x.senderHash)).toEqual([blocked]);
    expect((await SELF.fetch(`https://example.com/v3/blocks/${blocked}`, { method: "DELETE", headers: bearer(b) })).status).toBe(204);
    expect((await sendNote(bearer(a), b.accountId, fakeEnvelope(3))).status).toBe(201);
    expect((await inbox(bearer(b))).items.length).toBe(2);
    expect((await SELF.fetch(`https://example.com/v3/inbox/${"0".repeat(26)}/block`, { method: "POST", headers: bearer(b) })).status).toBe(404);
  });
});

describe("reports", () => {
  it("stores a report the operator can read; validates reason/excerpt; 20/day quota", async () => {
    const a = await makeAccount("dev-note-rep-0001"), b = await makeAccount("dev-note-rep-0002");
    const id = ((await (await sendNote(bearer(a), b.accountId)).json()) as { id: string }).id;
    const since = Date.now() - 1;
    const r = await SELF.fetch(`https://example.com/v3/inbox/${id}/report`, { method: "POST", headers: bearer(b), body: JSON.stringify({ reason: "harassment", excerpt: "decrypted text here" }) });
    expect(r.status).toBe(201);
    const { id: reportId } = await r.json() as { id: string };
    expect((await SELF.fetch(`https://example.com/v3/inbox/${id}/report`, { method: "POST", headers: bearer(b), body: JSON.stringify({ reason: "rude" }) })).status).toBe(400);
    expect((await SELF.fetch(`https://example.com/v3/inbox/${id}/report`, { method: "POST", headers: bearer(b), body: JSON.stringify({ reason: "spam", excerpt: "x".repeat(NOTE_LIMITS.excerptMaxChars + 1) }) })).status).toBe(400);
    expect((await SELF.fetch("https://example.com/v3/admin/reports", { headers: bearer(b) })).status).toBe(401);
    const admin = await SELF.fetch(`https://example.com/v3/admin/reports?since=${since}`, { headers: { "X-API-Key": ANALYTICS_KEY } });
    expect(admin.status).toBe(200);
    const { reports } = await admin.json() as { reports: { id: string; reporterAccountId: string; senderHash: string; inboxItemId: string; reason: string; excerpt: string | null }[] };
    const mine = reports.find((x) => x.id === reportId)!;
    expect(mine).toMatchObject({ reporterAccountId: b.accountId, inboxItemId: id, reason: "harassment", excerpt: "decrypted text here" });
    expect(mine.senderHash).toMatch(/^[0-9a-f]{64}$/);
    await env.V2_STORE.put(`report-quota:${b.accountId}:${new Date().toISOString().slice(0, 10)}`, String(NOTE_LIMITS.reportsPerDay));
    expect((await SELF.fetch(`https://example.com/v3/inbox/${id}/report`, { method: "POST", headers: bearer(b), body: JSON.stringify({ reason: "spam" }) })).status).toBe(429);
  });
});
