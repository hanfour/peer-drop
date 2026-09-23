// Passing-notes server side: pure helpers (this file's top half) and the
// /v3 notes routes (bottom half, added in later tasks). Everything here is
// ciphertext-only — the worker never sees a note's plaintext.
import type { Env } from "./index";

export const NOTE_LIMITS = {
  envelopeMaxBytes: 16 * 1024,
  perSenderPerDay: 200,
  perRecipientPerDay: 500,
  reportsPerDay: 20,
  powChallengesPerMinute: 60,
  powChallengeTtlSeconds: 300,
  powDifficulty: 16,
  inboxCap: 1000,
  retentionMs: 90 * 86_400_000,
  excerptMaxChars: 1000,
} as const;

// Crockford base32 (ULID spec): 10 time chars (ms since epoch) + 16 random.
const ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export function ulid(now: number = Date.now()): string {
  let t = now;
  let time = "";
  for (let i = 0; i < 10; i++) { time = ULID_ALPHABET[t % 32] + time; t = Math.floor(t / 32); }
  const rnd = new Uint8Array(16);
  crypto.getRandomValues(rnd);
  let rand = "";
  for (let i = 0; i < 16; i++) rand += ULID_ALPHABET[rnd[i] % 32]; // 256 % 32 === 0 → unbiased
  return time + rand;
}

const hex = (u8: Uint8Array) => Array.from(u8).map((b) => b.toString(16).padStart(2, "0")).join("");

/** Irreversible sender identifier: HMAC keyed by the server-only TOKEN_SECRET. */
export async function senderHash(secret: string, accountId: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode("note-sender:" + accountId))));
}

/** The exact string both sides feed to the hashcash: challenge|recipient|sha256hex(envelope). */
export async function notePoWMessage(challenge: string, recipientAccountId: string, envelopeBytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", envelopeBytes));
  return `${challenge}|${recipientAccountId}|${hex(digest)}`;
}

export type ParsedEnvelope = { ok: true; bytes: Uint8Array } | { ok: false; error: "invalid_envelope" | "too_large" };

/** Shape-check the base64 NoteEnvelope JSON without interpreting it. */
export function parseEnvelope(b64: string): ParsedEnvelope {
  if (typeof b64 !== "string" || b64.length > Math.ceil((NOTE_LIMITS.envelopeMaxBytes * 4) / 3) + 4) return { ok: false, error: "too_large" };
  let bytes: Uint8Array;
  try { bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)); } catch { return { ok: false, error: "invalid_envelope" }; }
  if (bytes.length > NOTE_LIMITS.envelopeMaxBytes) return { ok: false, error: "too_large" };
  let obj: Record<string, unknown>;
  try { obj = JSON.parse(new TextDecoder().decode(bytes)); } catch { return { ok: false, error: "invalid_envelope" }; }
  if (!obj || typeof obj !== "object" || obj.v !== 1) return { ok: false, error: "invalid_envelope" };
  const lenOf = (v: unknown): number => { if (typeof v !== "string") return -1; try { return atob(v).length; } catch { return -1; } };
  if (lenOf(obj.ephemeralKey) !== 32 || lenOf(obj.ephemeralKey2) !== 32 || lenOf(obj.nonce) !== 12 || lenOf(obj.ciphertext) < 16) return { ok: false, error: "invalid_envelope" };
  if (!Number.isInteger(obj.spkId)) return { ok: false, error: "invalid_envelope" };
  if (obj.opkId !== undefined && obj.opkId !== null && !Number.isInteger(obj.opkId)) return { ok: false, error: "invalid_envelope" };
  return { ok: true, bytes };
}

// Referenced by later tasks' route code; keeps the type import "used" for tsc.
export type NotesEnv = Env;

import { normalizeAccountId } from "./account";
import { verifyPoW } from "./pow";
import type { sendAPNs } from "./apns";
import { fanOutPush } from "./push";
import type { DiaryMeta } from "./diaryRoom";

export interface NotesAuth { deviceId: string; accountId: string }
export interface PushDeps { send: typeof sendAPNs; topicFor: (platform: string) => string }
export interface NotesRouteDeps { push: PushDeps }

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
}
const b64 = (u8: Uint8Array) => btoa(String.fromCharCode(...u8));
export const dayKey = () => new Date().toISOString().slice(0, 10);

export async function bumpQuota(kv: KVNamespace, key: string, limit: number, ttl: number): Promise<boolean> {
  const used = parseInt((await kv.get(key)) ?? "0", 10) || 0;
  if (used >= limit) return false;
  await kv.put(key, String(used + 1), { expirationTtl: ttl });
  return true;
}

/**
 * APNs fan-out to every device bound to the recipient account. Never
 * throws (see fanOutPush). Thin wrapper kept for its existing callers/
 * tests — the actual device-lookup/send loop now lives in the generic
 * fanOutPush (shared with diary.ts's per-event pushes and this file's own
 * kind="diaryKey" relay below).
 */
export async function fanOutNotePush(env: Env, recipientAccountId: string, itemId: string, deps: PushDeps): Promise<{ attempted: number }> {
  return fanOutPush(env, recipientAccountId, { alert: { "loc-key": "NOTE_RECEIVED" }, sound: "default", data: { type: "note", inboxItemId: itemId } }, deps);
}

// Same 26-char ULID shape diary.ts's own DIARY_ID_RE checks (kept as a
// separate constant, not imported, to avoid a notes.ts<->diary.ts value
// import cycle — diary.ts already imports several of this file's helpers).
const DIARY_ID_RE = /^[0-9A-HJKMNP-TV-Z]{26}$/;

/**
 * kind="diaryKey" relay (spec §3.3 step 3): resolve the diary's current DO
 * meta, gated by the same "never wake a DO for an id nobody created" D1
 * check diary.ts's own non-create routes use. Returns null when the diary
 * doesn't exist (D1 or DO 404) — the caller folds that into the same 403
 * not_member response a real member mismatch gets, rather than leaking
 * diary existence via a distinct error. Duplicated from diary.ts's
 * diaryExistsInD1/doCall (rather than imported) for the same reason as
 * DIARY_ID_RE above.
 */
async function diaryMetaForKeyRelay(env: Env, diaryId: string): Promise<DiaryMeta | null> {
  const row = await env.ACCOUNTS_DB.prepare(
    "SELECT 1 AS x FROM diary_members WHERE diary_id = ?1 UNION SELECT 1 AS x FROM diary_invites WHERE diary_id = ?2 LIMIT 1",
  ).bind(diaryId, diaryId).first();
  if (!row) return null;
  const stub = env.DIARY_ROOM.get(env.DIARY_ROOM.idFromName(diaryId));
  const metaResp = await stub.fetch("https://diary/meta");
  if (!metaResp.ok) return null;
  return await metaResp.json() as DiaryMeta;
}

/**
 * /v3 notes routes. Returns null when `path` is not one of ours so handleV3
 * can fall through. All of these accept the Mac key lane — notes are the
 * Mac's main feature and the lane's known weakness (self-asserted device
 * id) is bounded here by per-account quotas and sender-hash blocking.
 */
export async function handleNotesRoute(request: Request, url: URL, path: string, env: Env, auth: NotesAuth, deps: NotesRouteDeps): Promise<Response | null> {
  if (path === "/v3/pow/challenge" && request.method === "GET") {
    const minute = Math.floor(Date.now() / 60_000);
    if (!(await bumpQuota(env.V2_STORE, `pow-quota:${auth.accountId}:${minute}`, NOTE_LIMITS.powChallengesPerMinute, 120))) return json({ error: "rate_limited" }, 429);
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    const challenge = b64(bytes);
    await env.V2_STORE.put(`pow:${auth.accountId}:${challenge}`, "1", { expirationTtl: NOTE_LIMITS.powChallengeTtlSeconds });
    return json({ challenge });
  }

  const sendMatch = path.match(/^\/v3\/notes\/([^/]{1,32})$/);
  if (sendMatch && request.method === "POST") {
    const raw = await request.text();
    if (raw.length > 32 * 1024) return json({ error: "too_large" }, 413);
    let body: { envelope?: unknown; pow?: { challenge?: unknown; nonce?: unknown }; kind?: unknown; diaryId?: unknown } | null;
    try { body = JSON.parse(raw); } catch { body = null; }
    if (!body || typeof body.envelope !== "string" || !body.pow || typeof body.pow.challenge !== "string" || typeof body.pow.nonce !== "number" || !Number.isSafeInteger(body.pow.nonce) || body.pow.nonce < 0) {
      return json({ error: "missing_fields" }, 400);
    }
    if (body.kind !== undefined && body.kind !== "note" && body.kind !== "diaryKey") return json({ error: "missing_fields" }, 400);
    const kind: "note" | "diaryKey" = body.kind === "diaryKey" ? "diaryKey" : "note";
    // kind="diaryKey" is the key-relay envelope from spec §3.3 step 2 — a
    // key-holding member forwarding the diary key to a newly-joined member
    // who can't open metaCipher yet. diaryId is required and must be a
    // 26-char ULID (same shape as a diary's own client-generated id).
    if (kind === "diaryKey" && (typeof body.diaryId !== "string" || !DIARY_ID_RE.test(body.diaryId))) return json({ error: "missing_fields" }, 400);
    const diaryId = kind === "diaryKey" ? body.diaryId as string : undefined;
    let handle: string;
    try { handle = decodeURIComponent(sendMatch[1]); } catch { return json({ error: "recipient_not_found" }, 404); }
    const recipientId = normalizeAccountId(handle);
    if (!recipientId) return json({ error: "recipient_not_found" }, 404);
    const parsed = parseEnvelope(body.envelope);
    if (!parsed.ok) return json({ error: parsed.error }, parsed.error === "too_large" ? 413 : 400);
    // Single-use, server-issued challenge bound to the calling account.
    // Deleted before verification so a wrong nonce burns it (no offline grinding).
    const powKey = `pow:${auth.accountId}:${body.pow.challenge}`;
    if (!(await env.V2_STORE.get(powKey))) return json({ error: "bad_pow" }, 400);
    await env.V2_STORE.delete(powKey);
    const msg = await notePoWMessage(body.pow.challenge, recipientId, parsed.bytes);
    if (!(await verifyPoW(msg, body.pow.nonce, NOTE_LIMITS.powDifficulty))) return json({ error: "bad_pow" }, 400);
    const recipient = await env.ACCOUNTS_DB.prepare("SELECT account_id FROM accounts WHERE account_id = ?1").bind(recipientId).first<{ account_id: string }>();
    if (!recipient) return json({ error: "recipient_not_found" }, 404);
    // kind="diaryKey": both the sender and the recipient must be CURRENT
    // members of the named diary, checked before the block check below —
    // a non-member gets this real 403, never the blocked-sender fake 201
    // (that fake 201 stays reserved for the ordinary blocks-table check,
    // which still runs normally afterward for a member-to-member relay).
    if (kind === "diaryKey") {
      const meta = await diaryMetaForKeyRelay(env, diaryId as string);
      if (!meta || !meta.members.includes(auth.accountId) || !meta.members.includes(recipientId)) {
        return json({ error: "not_member" }, 403);
      }
    }
    const day = dayKey();
    // Sender quota first (the cost of trying at all), THEN the block check —
    // a blocked send must not also burn the RECIPIENT's daily quota, since
    // it never reaches their inbox either way (2026-09-19 fix: this used to
    // run after both quota bumps, so a blocked sender could exhaust a
    // recipient's inbox quota purely by retrying).
    if (!(await bumpQuota(env.V2_STORE, `note-quota:s:${auth.accountId}:${day}`, NOTE_LIMITS.perSenderPerDay, 2 * 86400))) return json({ error: "rate_limited" }, 429);
    const sh = await senderHash(env.TOKEN_SECRET, auth.accountId);
    const blocked = await env.ACCOUNTS_DB.prepare("SELECT 1 AS x FROM blocks WHERE account_id = ?1 AND sender_hash = ?2").bind(recipientId, sh).first();
    if (blocked) return json({ id: ulid() }, 201); // silent drop: the sender must not learn they are blocked
    if (!(await bumpQuota(env.V2_STORE, `note-quota:r:${recipientId}:${day}`, NOTE_LIMITS.perRecipientPerDay, 2 * 86400))) return json({ error: "rate_limited" }, 429);
    const id = ulid();
    const stub = env.ACCOUNT_INBOX.get(env.ACCOUNT_INBOX.idFromName(recipientId));
    const doResp = await stub.fetch(new Request("https://inbox/items", { method: "PUT", body: JSON.stringify({ id, kind, envelope: body.envelope, senderHash: sh, createdAt: Date.now() }) }));
    if (doResp.status === 507) return json({ error: "inbox_full" }, 507);
    if (!doResp.ok) return json({ error: "inbox_error" }, 502);
    if (kind === "diaryKey") {
      await fanOutPush(env, recipientId, { silent: true, data: { type: "diaryKey" } }, deps.push);
    } else {
      await fanOutNotePush(env, recipientId, id, deps.push);
    }
    return json({ id }, 201);
  }

  const inboxStub = () => env.ACCOUNT_INBOX.get(env.ACCOUNT_INBOX.idFromName(auth.accountId));

  if (path === "/v3/inbox" && request.method === "GET") {
    const after = url.searchParams.get("after") ?? "";
    const limit = url.searchParams.get("limit") ?? "50";
    if (after && !/^[0-9A-Z]{26}$/.test(after)) return json({ error: "invalid_cursor" }, 400);
    const resp = await inboxStub().fetch(`https://inbox/items?after=${after}&limit=${encodeURIComponent(limit)}`);
    if (!resp.ok) return json({ error: "inbox_error" }, 502);
    return json(await resp.json(), resp.status);
  }

  const itemMatch = path.match(/^\/v3\/inbox\/([0-9A-Z]{26})(?:\/(read|block|report))?$/);
  if (itemMatch) {
    const id = itemMatch[1];
    const sub = itemMatch[2];
    if (request.method === "POST" && sub === "read") {
      await inboxStub().fetch(`https://inbox/items/${id}/read`, { method: "POST" });
      return new Response(null, { status: 204 });
    }
    if (request.method === "DELETE" && !sub) {
      await inboxStub().fetch(`https://inbox/items/${id}`, { method: "DELETE" });
      return new Response(null, { status: 204 });
    }
    if (request.method === "POST" && (sub === "block" || sub === "report")) {
      const senderResp = await inboxStub().fetch(`https://inbox/items/${id}/sender`);
      if (!senderResp.ok) return json({ error: "not_found" }, 404);
      const { senderHash: sh } = await senderResp.json() as { senderHash: string };
      if (sub === "block") {
        await env.ACCOUNTS_DB.prepare("INSERT OR IGNORE INTO blocks (account_id, sender_hash, created_at) VALUES (?1, ?2, ?3)").bind(auth.accountId, sh, Date.now()).run();
        return json({ blocked: sh });
      }
      const raw = await request.text();
      if (raw.length > 8 * 1024) return json({ error: "too_large" }, 413);
      let body: { reason?: unknown; excerpt?: unknown } | null;
      try { body = JSON.parse(raw || "null"); } catch { body = null; }
      if (!body || typeof body.reason !== "string" || !["spam", "harassment", "other"].includes(body.reason)) return json({ error: "invalid_report" }, 400);
      let excerpt: string | null = null;
      if (body.excerpt !== undefined && body.excerpt !== null) {
        if (typeof body.excerpt !== "string" || Array.from(body.excerpt).length > NOTE_LIMITS.excerptMaxChars) return json({ error: "invalid_report" }, 400);
        excerpt = body.excerpt;
      }
      if (!(await bumpQuota(env.V2_STORE, `report-quota:${auth.accountId}:${dayKey()}`, NOTE_LIMITS.reportsPerDay, 2 * 86400))) return json({ error: "rate_limited" }, 429);
      const reportId = ulid();
      await env.ACCOUNTS_DB.prepare("INSERT INTO reports (id, reporter_account_id, sender_hash, inbox_item_id, reason, excerpt, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
        .bind(reportId, auth.accountId, sh, id, body.reason, excerpt, Date.now()).run();
      return json({ id: reportId }, 201);
    }
  }

  if (path === "/v3/blocks" && request.method === "GET") {
    const rows = (await env.ACCOUNTS_DB.prepare("SELECT sender_hash, created_at FROM blocks WHERE account_id = ?1 ORDER BY created_at DESC").bind(auth.accountId).all<{ sender_hash: string; created_at: number }>()).results;
    return json(rows.map((r) => ({ senderHash: r.sender_hash, createdAt: r.created_at })));
  }
  const unblockMatch = path.match(/^\/v3\/blocks\/([0-9a-f]{64})$/);
  if (unblockMatch && request.method === "DELETE") {
    await env.ACCOUNTS_DB.prepare("DELETE FROM blocks WHERE account_id = ?1 AND sender_hash = ?2").bind(auth.accountId, unblockMatch[1]).run();
    return new Response(null, { status: 204 });
  }

  return null;
}
