// One Durable Object per account: the ciphertext inbox for passing notes.
//
// Storage layout (key/value API, like PreKeyStore/DeviceInbox — no SQL):
//   meta:<ulid> → InboxMeta   (~150 B: list/paginate/cap-check without loading envelopes)
//   item:<ulid> → envelope    (base64 NoteEnvelope JSON, ≤ 16 KB)
// ULIDs sort by creation time, so a key-ordered list IS chronological.
import { NOTE_LIMITS } from "./notes";

export interface InboxMeta {
  id: string;
  kind: string;
  senderHash: string;
  createdAt: number;
  readAt: number | null;
  expiresAt: number;
}
export interface InboxItemOut { id: string; kind: string; envelope: string; createdAt: number; readAt: number | null }

/** Next 03:00 UTC strictly after `now`. */
export function nextCleanupAt(now: number): number {
  const d = new Date(now);
  const today = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), 3, 0, 0);
  return today > now ? today : today + 86_400_000;
}

const ID_RE = /^[0-9A-Z]{26}$/;

export class AccountInbox {
  constructor(private state: DurableObjectState, _env: unknown) {}

  private json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const storage = this.state.storage;

    if (path === "/items" && request.method === "PUT") {
      const body = await request.json() as { id: string; kind: string; envelope: string; senderHash: string; createdAt: number };
      if (!ID_RE.test(body.id)) return this.json({ error: "invalid_id" }, 400);
      const metas = await storage.list<InboxMeta>({ prefix: "meta:" });
      if (metas.size >= NOTE_LIMITS.inboxCap) {
        const oldestRead = [...metas.values()].find((m) => m.readAt !== null); // key order = oldest first
        if (!oldestRead) return this.json({ error: "inbox_full" }, 507);
        await storage.delete([`meta:${oldestRead.id}`, `item:${oldestRead.id}`]);
      }
      const meta: InboxMeta = { id: body.id, kind: body.kind, senderHash: body.senderHash, createdAt: body.createdAt, readAt: null, expiresAt: body.createdAt + NOTE_LIMITS.retentionMs };
      await storage.put({ [`meta:${body.id}`]: meta, [`item:${body.id}`]: body.envelope });
      if ((await storage.getAlarm()) === null) await storage.setAlarm(nextCleanupAt(Date.now()));
      return this.json({ id: body.id }, 201);
    }

    if (path === "/items" && request.method === "GET") {
      const after = url.searchParams.get("after");
      const limit = Math.min(Math.max(parseInt(url.searchParams.get("limit") ?? "50", 10) || 50, 1), 100);
      const metas = await storage.list<InboxMeta>({ prefix: "meta:", startAfter: after ? `meta:${after}` : undefined, limit: limit + 1 });
      const all = [...metas.values()];
      const page = all.slice(0, limit);
      const envelopes = await storage.get<string>(page.map((m) => `item:${m.id}`));
      const items: InboxItemOut[] = page.map((m) => ({ id: m.id, kind: m.kind, envelope: envelopes.get(`item:${m.id}`) ?? "", createdAt: m.createdAt, readAt: m.readAt }));
      const out: { items: InboxItemOut[]; nextAfter?: string } = { items };
      if (all.length > limit && page.length) out.nextAfter = page[page.length - 1].id;
      return this.json(out);
    }

    const m = path.match(/^\/items\/([0-9A-Z]{26})(?:\/(read|sender))?$/);
    if (m) {
      const id = m[1];
      const sub = m[2];
      const meta = await storage.get<InboxMeta>(`meta:${id}`);
      if (request.method === "POST" && sub === "read") {
        if (meta && meta.readAt === null) { meta.readAt = Date.now(); await storage.put(`meta:${id}`, meta); }
        return new Response(null, { status: 204 });
      }
      if (request.method === "GET" && sub === "sender") {
        return meta ? this.json({ senderHash: meta.senderHash }) : this.json({ error: "not_found" }, 404);
      }
      if (request.method === "DELETE" && !sub) {
        await storage.delete([`meta:${id}`, `item:${id}`]);
        return new Response(null, { status: 204 });
      }
    }
    return this.json({ error: "not_found" }, 404);
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    const storage = this.state.storage;
    const metas = await storage.list<InboxMeta>({ prefix: "meta:" });
    const expired = [...metas.values()].filter((m) => m.expiresAt < now);
    for (let i = 0; i < expired.length; i += 64) {
      await storage.delete(expired.slice(i, i + 64).flatMap((m) => [`meta:${m.id}`, `item:${m.id}`]));
    }
    await storage.setAlarm(nextCleanupAt(now));
  }
}
