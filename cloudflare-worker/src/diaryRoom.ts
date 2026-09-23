// One Durable Object per exchange diary, named by the client-generated
// diaryId (ULID). Key/value storage (same API as AccountInbox — no SQL):
//
//   meta                  → DiaryMeta
//   ev:<seq padded 12>    → DiaryEvent   (seq is the shared per-diary counter;
//                                          join/leave/entry/comment/like/pass/skip
//                                          all consume the same sequence)
//   eid:<eventId>         → seq          (idempotency: POST /events resend)
//   like:<refSeq>:<accountId> → seq      (idempotency: same person liking the
//                                          same entry twice returns the FIRST
//                                          like's seq instead of a duplicate)
//
// D1 (diary_members / diary_invites) is only an index for "which diaries is
// this account in" / "which diary does this invite code point to" — the
// live membership set, invite code and turn order live here, in the DO.
import { generateAccountId } from "./account";

export interface DiaryMeta {
  diaryId: string;
  ownerAccountId: string;
  members: string[]; // order = turn order
  holderIndex: number;
  seq: number;
  inviteCode: string;
  state: "open" | "closed";
  keyEpoch: number;
  metaCipher: string;
  createdAt: number;
  bytesUsed: number;
}

export type DiaryEventType = "entry" | "comment" | "like" | "pass" | "skip" | "join" | "leave";

export interface DiaryEvent {
  seq: number;
  eventId: string;
  type: DiaryEventType;
  authorAccountId: string;
  refSeq?: number;
  payloadCipher?: string;
  createdAt: number;
  skipped?: string;
}

const POSTABLE_EVENT_TYPES = new Set<string>(["entry", "comment", "like", "pass", "skip"]);
export const MAX_MEMBERS = 12;
const MAX_BYTES_USED = 64 * 1024 * 1024;
const MAX_PAYLOAD_BYTES = 64 * 1024;
const DEFAULT_EVENTS_LIMIT = 100;
const MAX_EVENTS_LIMIT = 500;

const padSeq = (n: number): string => String(n).padStart(12, "0");
const evKey = (seq: number): string => `ev:${padSeq(seq)}`;

/** atob() length of a base64 string, or null if it isn't valid base64. */
function decodedByteLength(b64: string): number | null {
  try {
    return atob(b64).length;
  } catch {
    return null;
  }
}

export class DiaryRoom {
  constructor(private state: DurableObjectState, _env: unknown) {}

  private json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
  }

  private getMeta(): Promise<DiaryMeta | undefined> {
    return this.state.storage.get<DiaryMeta>("meta");
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const storage = this.state.storage;

    // ---- create / idempotent re-create -------------------------------
    if (path === "/init" && request.method === "POST") {
      const body = await request.json() as { diaryId: string; ownerAccountId: string; metaCipher: string; inviteCode?: string };
      const existing = await this.getMeta();
      if (existing) {
        if (existing.ownerAccountId === body.ownerAccountId) return this.json(existing, 200);
        return this.json({ error: "diary_exists" }, 409);
      }
      const meta: DiaryMeta = {
        diaryId: body.diaryId,
        ownerAccountId: body.ownerAccountId,
        members: [body.ownerAccountId],
        holderIndex: 0,
        seq: 0,
        inviteCode: body.inviteCode ?? generateAccountId(),
        state: "open",
        keyEpoch: 1,
        metaCipher: body.metaCipher,
        createdAt: Date.now(),
        bytesUsed: 0,
      };
      await storage.put("meta", meta);
      return this.json(meta, 201);
    }

    // ---- meta ----------------------------------------------------------
    if (path === "/meta" && request.method === "GET") {
      const meta = await this.getMeta();
      if (!meta) return this.json({ error: "not_found" }, 404);
      return this.json(meta);
    }

    // ---- join ------------------------------------------------------------
    if (path === "/join" && request.method === "POST") {
      const body = await request.json() as { accountId: string; inviteCode?: string };
      const meta = await this.getMeta();
      if (!meta) return this.json({ error: "not_found" }, 404);
      // Idempotent short-circuit takes priority over the code/closed/full
      // checks below — an existing member re-joining (e.g. replaying a
      // stale invite link after a code reset) needs no fresh authorization.
      if (meta.members.includes(body.accountId)) return this.json({ added: false, meta }, 200);
      // Authoritative check: D1's diary_invites only resolves a code to a
      // diaryId (see diary.ts) — whether that code is CURRENTLY valid is
      // decided here, against the DO's own meta.inviteCode, so a route-level
      // precheck can never be bypassed by a stale/tampered D1 row or a race
      // with a concurrent invite/reset.
      if (meta.inviteCode !== body.inviteCode) return this.json({ error: "bad_code" }, 403);
      if (meta.state === "closed") return this.json({ error: "diary_closed" }, 403);
      if (meta.members.length >= MAX_MEMBERS) return this.json({ error: "diary_full_members" }, 409);
      meta.members.push(body.accountId);
      meta.seq += 1;
      // "srv:" is a reserved eventId prefix a client can never produce (its
      // eventIds are ULIDs) — no `eid:` entry needed since nobody can ever
      // replay-POST this id.
      const event: DiaryEvent = {
        seq: meta.seq,
        eventId: `srv:join:${body.accountId}:${meta.seq}`,
        type: "join",
        authorAccountId: body.accountId,
        createdAt: Date.now(),
      };
      await storage.put({ meta, [evKey(meta.seq)]: event });
      return this.json({ added: true, meta }, 201);
    }

    // ---- leave -------------------------------------------------------
    if (path === "/leave" && request.method === "POST") {
      const body = await request.json() as { accountId: string };
      const meta = await this.getMeta();
      if (!meta) return this.json({ error: "not_found" }, 404);
      const idx = meta.members.indexOf(body.accountId);
      if (idx === -1) return this.json({ meta }, 200); // not a member: no-op
      meta.members.splice(idx, 1);
      if (meta.members.length === 0) {
        meta.state = "closed";
        meta.holderIndex = 0;
      } else {
        if (idx === meta.holderIndex) meta.holderIndex = idx % meta.members.length;
        else if (idx < meta.holderIndex) meta.holderIndex -= 1;
        if (meta.ownerAccountId === body.accountId) meta.ownerAccountId = meta.members[0];
      }
      meta.seq += 1;
      const event: DiaryEvent = {
        seq: meta.seq,
        eventId: `srv:leave:${body.accountId}:${meta.seq}`,
        type: "leave",
        authorAccountId: body.accountId,
        createdAt: Date.now(),
      };
      await storage.put({ meta, [evKey(meta.seq)]: event });
      return this.json({ meta }, 200);
    }

    // ---- close (owner-only) -------------------------------------------
    if (path === "/close" && request.method === "POST") {
      const body = await request.json() as { accountId: string };
      const meta = await this.getMeta();
      if (!meta) return this.json({ error: "not_found" }, 404);
      if (meta.ownerAccountId !== body.accountId) return this.json({ error: "not_owner" }, 403);
      meta.state = "closed";
      await storage.put("meta", meta);
      return this.json({ meta }, 200);
    }

    // ---- invite/reset (owner-only) -------------------------------------
    if (path === "/invite/reset" && request.method === "POST") {
      const body = await request.json() as { accountId: string };
      const meta = await this.getMeta();
      if (!meta) return this.json({ error: "not_found" }, 404);
      if (meta.ownerAccountId !== body.accountId) return this.json({ error: "not_owner" }, 403);
      const previousCode = meta.inviteCode;
      meta.inviteCode = generateAccountId();
      await storage.put("meta", meta);
      return this.json({ inviteCode: meta.inviteCode, previousCode });
    }

    // ---- events: list ----------------------------------------------------
    if (path === "/events" && request.method === "GET") {
      const since = Math.max(parseInt(url.searchParams.get("since") ?? "0", 10) || 0, 0);
      const limitRaw = parseInt(url.searchParams.get("limit") ?? String(DEFAULT_EVENTS_LIMIT), 10);
      const limit = Math.min(Math.max(Number.isNaN(limitRaw) ? DEFAULT_EVENTS_LIMIT : limitRaw, 1), MAX_EVENTS_LIMIT);
      const results = await storage.list<DiaryEvent>({ prefix: "ev:", startAfter: evKey(since), limit: limit + 1 });
      const all = [...results.values()];
      const page = all.slice(0, limit);
      const out: { events: DiaryEvent[]; nextSince?: number } = { events: page };
      if (all.length > limit && page.length) out.nextSince = page[page.length - 1].seq;
      return this.json(out);
    }

    // ---- events: post ------------------------------------------------
    if (path === "/events" && request.method === "POST") {
      const body = await request.json() as {
        accountId: string; eventId: string; type: string; refSeq?: number; payloadCipher?: string;
      };
      const meta = await this.getMeta();
      if (!meta) return this.json({ error: "not_found" }, 404);
      if (!meta.members.includes(body.accountId)) return this.json({ error: "not_member" }, 403);
      if (meta.state === "closed") return this.json({ error: "diary_closed" }, 403);
      if (!POSTABLE_EVENT_TYPES.has(body.type)) return this.json({ error: "bad_type" }, 400);

      // Exact-eventId replay: return the original result untouched (no
      // re-validation, no further index movement, no byte accounting).
      const existingSeq = await storage.get<number>(`eid:${body.eventId}`);
      if (existingSeq !== undefined) {
        const event = await storage.get<DiaryEvent>(evKey(existingSeq));
        return this.json({ seq: existingSeq, holderIndex: meta.holderIndex, event, meta }, 200);
      }

      const isHolder = meta.members[meta.holderIndex] === body.accountId;
      const isOwner = meta.ownerAccountId === body.accountId;
      let likeDedupKey: string | null = null;

      if (body.type === "entry") {
        if (!isHolder) return this.json({ error: "not_holder" }, 403);
        if (typeof body.payloadCipher !== "string" || body.payloadCipher.length === 0) return this.json({ error: "bad_payload" }, 400);
        if (body.refSeq !== undefined) return this.json({ error: "bad_ref" }, 400);
      } else if (body.type === "pass") {
        if (!isHolder) return this.json({ error: "not_holder" }, 403);
        if (body.payloadCipher !== undefined) return this.json({ error: "bad_payload" }, 400);
        if (body.refSeq !== undefined) return this.json({ error: "bad_ref" }, 400);
      } else if (body.type === "skip") {
        if (!isOwner) return this.json({ error: "not_owner" }, 403);
        if (meta.members.length < 2) return this.json({ error: "skip_self" }, 403);
        if (meta.members[meta.holderIndex] === meta.ownerAccountId) return this.json({ error: "skip_self" }, 403);
        if (body.payloadCipher !== undefined) return this.json({ error: "bad_payload" }, 400);
        if (body.refSeq !== undefined) return this.json({ error: "bad_ref" }, 400);
      } else if (body.type === "comment") {
        if (typeof body.payloadCipher !== "string" || body.payloadCipher.length === 0) return this.json({ error: "bad_payload" }, 400);
        if (typeof body.refSeq !== "number") return this.json({ error: "bad_ref" }, 400);
        const target = await storage.get<DiaryEvent>(evKey(body.refSeq));
        if (!target || target.type !== "entry") return this.json({ error: "bad_ref" }, 400);
      } else if (body.type === "like") {
        if (body.payloadCipher !== undefined) return this.json({ error: "bad_payload" }, 400);
        if (typeof body.refSeq !== "number") return this.json({ error: "bad_ref" }, 400);
        const target = await storage.get<DiaryEvent>(evKey(body.refSeq));
        if (!target || target.type !== "entry") return this.json({ error: "bad_ref" }, 400);
        likeDedupKey = `like:${body.refSeq}:${body.accountId}`;
        const existingLikeSeq = await storage.get<number>(likeDedupKey);
        if (existingLikeSeq !== undefined) {
          const existingEvent = await storage.get<DiaryEvent>(evKey(existingLikeSeq));
          return this.json({ seq: existingLikeSeq, holderIndex: meta.holderIndex, event: existingEvent, meta }, 200);
        }
      }

      let payloadLen = 0;
      if (body.payloadCipher !== undefined) {
        const len = decodedByteLength(body.payloadCipher);
        if (len === null) return this.json({ error: "bad_payload" }, 400);
        if (len > MAX_PAYLOAD_BYTES) return this.json({ error: "too_large" }, 413);
        payloadLen = len;
      }
      if (payloadLen > 0 && meta.bytesUsed + payloadLen > MAX_BYTES_USED) {
        return this.json({ error: "diary_full" }, 507);
      }

      meta.seq += 1;
      const seq = meta.seq;
      const event: DiaryEvent = {
        seq,
        eventId: body.eventId,
        type: body.type as DiaryEventType,
        authorAccountId: body.accountId,
        createdAt: Date.now(),
      };
      if (body.refSeq !== undefined) event.refSeq = body.refSeq;
      if (body.payloadCipher !== undefined) event.payloadCipher = body.payloadCipher;
      if (body.type === "pass" || body.type === "skip") {
        if (body.type === "skip") event.skipped = meta.members[meta.holderIndex];
        meta.holderIndex = (meta.holderIndex + 1) % meta.members.length;
      }
      meta.bytesUsed += payloadLen;

      const writes: Record<string, unknown> = { meta, [evKey(seq)]: event, [`eid:${body.eventId}`]: seq };
      if (likeDedupKey) writes[likeDedupKey] = seq;
      await storage.put(writes);

      return this.json({ seq, holderIndex: meta.holderIndex, event, meta }, 201);
    }

    // ---- single event lookup ------------------------------------------
    const eventMatch = path.match(/^\/event\/(\d+)$/);
    if (eventMatch && request.method === "GET") {
      const seq = parseInt(eventMatch[1], 10);
      const event = await storage.get<DiaryEvent>(evKey(seq));
      if (!event) return this.json({ error: "not_found" }, 404);
      return this.json(event);
    }

    return this.json({ error: "not_found" }, 404);
  }
}
