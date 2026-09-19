import { env, runInDurableObject, runDurableObjectAlarm } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { NOTE_LIMITS, ulid } from "../notes";
import type { AccountInbox, InboxMeta } from "../accountInbox";

const stubFor = (name: string) => env.ACCOUNT_INBOX.get(env.ACCOUNT_INBOX.idFromName(name));
const put = (stub: DurableObjectStub, id: string, extra: Record<string, unknown> = {}) =>
  stub.fetch("https://inbox/items", { method: "PUT", body: JSON.stringify({ id, kind: "note", envelope: "ZW52", senderHash: "h".repeat(64), createdAt: Date.now(), ...extra }) });

describe("AccountInbox DO", () => {
  it("stores items, pages them in id order and hides senderHash", async () => {
    const stub = stubFor("acct-do-page");
    const ids = [ulid(1000), ulid(2000), ulid(3000)];
    for (const id of ids) expect((await put(stub, id)).status).toBe(201);
    const p1 = await (await stub.fetch("https://inbox/items?limit=2")).json() as { items: { id: string; envelope: string; readAt: null; senderHash?: string }[]; nextAfter?: string };
    expect(p1.items.map((i) => i.id)).toEqual([ids[0], ids[1]]);
    expect(p1.items[0].envelope).toBe("ZW52");
    expect(p1.items[0].readAt).toBeNull();
    expect(p1.items[0].senderHash).toBeUndefined();
    expect(p1.nextAfter).toBe(ids[1]);
    const p2 = await (await stub.fetch(`https://inbox/items?after=${p1.nextAfter}&limit=2`)).json() as { items: { id: string }[]; nextAfter?: string };
    expect(p2.items.map((i) => i.id)).toEqual([ids[2]]);
    expect(p2.nextAfter).toBeUndefined();
  });
  it("read is idempotent, delete is idempotent, sender lookup works", async () => {
    const stub = stubFor("acct-do-read");
    const id = ulid();
    await put(stub, id);
    expect((await stub.fetch(`https://inbox/items/${id}/read`, { method: "POST" })).status).toBe(204);
    expect((await stub.fetch(`https://inbox/items/${id}/read`, { method: "POST" })).status).toBe(204);
    const page = await (await stub.fetch("https://inbox/items")).json() as { items: { readAt: number | null }[] };
    expect(typeof page.items[0].readAt).toBe("number");
    expect(await (await stub.fetch(`https://inbox/items/${id}/sender`)).json()).toEqual({ senderHash: "h".repeat(64) });
    expect((await stub.fetch(`https://inbox/items/${id}`, { method: "DELETE" })).status).toBe(204);
    expect((await stub.fetch(`https://inbox/items/${id}`, { method: "DELETE" })).status).toBe(204);
    expect((await stub.fetch(`https://inbox/items/${id}/sender`)).status).toBe(404);
  });
  it("refuses at the cap when nothing is read, then evicts the oldest read item", async () => {
    const stub = stubFor("acct-do-cap");
    // Seed 1,000 metas straight into storage (a PUT per item would take minutes).
    await runInDurableObject(stub, async (_instance: AccountInbox, state) => {
      const entries: Record<string, InboxMeta | string> = {};
      for (let i = 0; i < NOTE_LIMITS.inboxCap; i++) {
        const id = ulid(1_000_000 + i);
        entries[`meta:${id}`] = { id, kind: "note", senderHash: "x", createdAt: 1_000_000 + i, readAt: null, expiresAt: 9e15 };
        entries[`item:${id}`] = "ZW52";
        if (Object.keys(entries).length >= 128) { await state.storage.put(entries); for (const k of Object.keys(entries)) delete entries[k]; }
      }
      if (Object.keys(entries).length) await state.storage.put(entries);
    });
    const full = await put(stub, ulid(2_000_000));
    expect(full.status).toBe(507);
    expect(await full.json()).toEqual({ error: "inbox_full" });
    const first = await (await stub.fetch("https://inbox/items?limit=1")).json() as { items: { id: string }[] };
    await stub.fetch(`https://inbox/items/${first.items[0].id}/read`, { method: "POST" });
    expect((await put(stub, ulid(2_000_001))).status).toBe(201);
    expect((await stub.fetch(`https://inbox/items/${first.items[0].id}/sender`)).status).toBe(404);
  });
  it("alarm deletes expired items and reschedules", async () => {
    const stub = stubFor("acct-do-alarm");
    const fresh = ulid(), stale = ulid(5000);
    await put(stub, fresh);
    await put(stub, stale, { createdAt: Date.now() - NOTE_LIMITS.retentionMs - 1000 });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const page = await (await stub.fetch("https://inbox/items")).json() as { items: { id: string }[] };
    expect(page.items.map((i) => i.id)).toEqual([fresh]);
    await runInDurableObject(stub, async (_i: AccountInbox, state) => { expect(await state.storage.getAlarm()).not.toBeNull(); });
  });
});
