// Exchange-diary server side: pure helpers (top) and the /v3/diaries* HTTP
// routes (bottom). Everything here is ciphertext-only — the worker never
// sees an entry's, comment's or diary name's plaintext (`metaCipher` and
// `payloadCipher` are opaque base64 blobs to it).
//
// D1 (`diary_members` / `diary_invites`) is only an index — "which diaries
// is this account in" / "which diary does this invite code resolve to" —
// used (a) to gate routes on a nonexistent diaryId without ever waking its
// Durable Object, and (b) for the create/join account-level 20-diary cap,
// which spans diaries and so can't be answered by any single DO. The live
// membership set, turn order and invite code are owned by the `DiaryRoom`
// DO (see ./diaryRoom.ts) — D1 rows are repaired (INSERT OR IGNORE) on
// every create/join in case a prior request's D1 write failed after its DO
// write already succeeded (DO operations are idempotent, so replaying them
// is always safe).
import type { Env } from "./index";
import { bumpQuota, dayKey, json, NOTE_LIMITS, senderHash, ulid } from "./notes";
import type { PushDeps } from "./notes";
import { generateAccountId, normalizeAccountId } from "./account";
import type { DiaryEvent, DiaryMeta } from "./diaryRoom";

export interface DiaryAuth { deviceId: string; accountId: string }
export interface DiaryRouteDeps { push: PushDeps }

const DIARY_LIMIT_PER_ACCOUNT = 20;
const JOIN_FAIL_LIMIT_PER_HOUR = 10;
const REQUEST_KEY_LIMIT_PER_HOUR = 6;
const MAX_CREATE_BODY_BYTES = 4 * 1024;
const MAX_EVENT_BODY_BYTES = 96 * 1024;
const MAX_REPORT_BODY_BYTES = 8 * 1024;

// Same 32-symbol Crockford-ish alphabet as notes.ts's ULID_ALPHABET (26
// chars, excludes I/L/O/U).
const DIARY_ID_RE = /^[0-9A-HJKMNP-TV-Z]{26}$/;
function isValidDiaryId(id: string): boolean {
  return DIARY_ID_RE.test(id);
}

/** UTC yyyyMMddHH — the hour bucket used by the join-fail and key-request rate limits. */
function hourKey(now: number = Date.now()): string {
  const d = new Date(now);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}${pad(d.getUTCHours())}`;
}

/**
 * All non-create routes must 404 (without ever calling `idFromName`'s
 * stub `.fetch` — i.e. without waking the DO) for a diaryId nobody has
 * created, so an attacker can't spray random ids into existence. Checked
 * against either index table since both are written before create/join
 * return 2xx and neither is ever the sole source of truth on its own
 * (`diary_invites` survives a diary being emptied by leaves;
 * `diary_members` is what a freshly-created, not-yet-joined-by-anyone-else
 * diary has).
 */
async function diaryExistsInD1(db: D1Database, diaryId: string): Promise<boolean> {
  const row = await db.prepare(
    "SELECT 1 AS x FROM diary_members WHERE diary_id = ?1 UNION SELECT 1 AS x FROM diary_invites WHERE diary_id = ?2 LIMIT 1",
  ).bind(diaryId, diaryId).first();
  return !!row;
}

function diaryStub(env: Env, diaryId: string): DurableObjectStub {
  return env.DIARY_ROOM.get(env.DIARY_ROOM.idFromName(diaryId));
}

async function doCall(env: Env, diaryId: string, path: string, init?: RequestInit): Promise<Response> {
  return diaryStub(env, diaryId).fetch(`https://diary${path}`, init);
}

/** Shared by create and both join routes — a caller already in the target diary skips its own cap. */
async function underDiaryLimit(db: D1Database, accountId: string, diaryId: string): Promise<boolean> {
  const alreadyMember = await db.prepare("SELECT 1 AS x FROM diary_members WHERE account_id = ?1 AND diary_id = ?2")
    .bind(accountId, diaryId).first();
  if (alreadyMember) return true;
  const row = await db.prepare("SELECT COUNT(*) AS n FROM diary_members WHERE account_id = ?1").bind(accountId).first<{ n: number }>();
  return (row?.n ?? 0) < DIARY_LIMIT_PER_ACCOUNT;
}

/** GET /v3/diaries/:id, GET .../events, .../request-key and .../report all require the caller to be a CURRENT member — resolved here via the DO's own meta (source of truth for membership). */
async function requireMember(env: Env, diaryId: string, accountId: string): Promise<{ meta: DiaryMeta } | Response> {
  if (!(await diaryExistsInD1(env.ACCOUNTS_DB, diaryId))) return json({ error: "not_found" }, 404);
  const metaResp = await doCall(env, diaryId, "/meta");
  if (!metaResp.ok) return json({ error: "not_found" }, 404);
  const meta = await metaResp.json() as DiaryMeta;
  if (!meta.members.includes(accountId)) return json({ error: "not_member" }, 403);
  return { meta };
}

/** A wrong/malformed invite code: rate-limited per calling account, 10/hour, then 429. */
async function failJoinCode(env: Env, accountId: string): Promise<Response> {
  const allowed = await bumpQuota(env.V2_STORE, `diary-join-fail:${accountId}:${hourKey()}`, JOIN_FAIL_LIMIT_PER_HOUR, 2 * 3600);
  if (!allowed) return json({ error: "rate_limited" }, 429);
  return json({ error: "bad_code" }, 403);
}

/** Shared tail of both join routes once `diaryId` + a validated invite code are known. */
async function performJoin(env: Env, diaryId: string, accountId: string): Promise<Response> {
  const db = env.ACCOUNTS_DB;
  if (!(await underDiaryLimit(db, accountId, diaryId))) return json({ error: "diary_limit" }, 409);
  const joinResp = await doCall(env, diaryId, "/join", { method: "POST", body: JSON.stringify({ accountId }) });
  if (!joinResp.ok) return json(await joinResp.json(), joinResp.status);
  const { added, meta } = await joinResp.json() as { added: boolean; meta: DiaryMeta };
  try {
    await db.prepare("INSERT OR IGNORE INTO diary_members (account_id, diary_id, joined_at) VALUES (?1, ?2, ?3)")
      .bind(accountId, diaryId, Date.now()).run();
  } catch (e) {
    console.error("diary join: D1 write failed", String(e));
    return json({ error: "d1_error" }, 500);
  }
  return json(
    { diaryId, members: meta.members, holderIndex: meta.holderIndex, ownerAccountId: meta.ownerAccountId, state: meta.state, seq: meta.seq, metaCipher: meta.metaCipher },
    added ? 201 : 200,
  );
}

/**
 * /v3/diaries* routes. Returns null when `path` is not one of ours so
 * handleV3 can fall through (mirrors handleNotesRoute). All of these accept
 * the Mac key lane (same as notes — see NotesAuth). `deps.push` is unused
 * in this task; diary pushes land in a later task.
 */
export async function handleDiaryRoute(request: Request, url: URL, path: string, env: Env, auth: DiaryAuth, _deps: DiaryRouteDeps): Promise<Response | null> {
  const db = env.ACCOUNTS_DB;

  // ---- POST /v3/diaries — create / idempotent re-create ----------------
  if (path === "/v3/diaries" && request.method === "POST") {
    const raw = await request.text();
    if (raw.length > MAX_CREATE_BODY_BYTES) return json({ error: "too_large" }, 413);
    let body: { diaryId?: unknown; metaCipher?: unknown } | null;
    try { body = JSON.parse(raw); } catch { body = null; }
    if (!body || typeof body.diaryId !== "string" || typeof body.metaCipher !== "string") return json({ error: "missing_fields" }, 400);
    if (!isValidDiaryId(body.diaryId)) return json({ error: "invalid_id" }, 400);
    const diaryId = body.diaryId;
    const metaCipher = body.metaCipher;

    if (!(await underDiaryLimit(db, auth.accountId, diaryId))) return json({ error: "diary_limit" }, 409);

    const initResp = await doCall(env, diaryId, "/init", {
      method: "POST",
      body: JSON.stringify({ diaryId, ownerAccountId: auth.accountId, metaCipher, inviteCode: generateAccountId() }),
    });
    if (!initResp.ok) return json(await initResp.json(), initResp.status);
    const meta = await initResp.json() as DiaryMeta;
    const isNew = initResp.status === 201;

    try {
      await db.batch([
        db.prepare("INSERT OR IGNORE INTO diary_members (account_id, diary_id, joined_at) VALUES (?1, ?2, ?3)").bind(auth.accountId, diaryId, Date.now()),
        db.prepare("INSERT OR IGNORE INTO diary_invites (invite_code, diary_id) VALUES (?1, ?2)").bind(meta.inviteCode, diaryId),
      ]);
    } catch (e) {
      console.error("diary create: D1 write failed", String(e));
      return json({ error: "d1_error" }, 500);
    }
    return json({ diaryId, inviteCode: meta.inviteCode }, isNew ? 201 : 200);
  }

  // ---- GET /v3/diaries — this account's diary list ----------------------
  if (path === "/v3/diaries" && request.method === "GET") {
    const rows = (await db.prepare("SELECT diary_id, joined_at FROM diary_members WHERE account_id = ?1 ORDER BY joined_at")
      .bind(auth.accountId).all<{ diary_id: string; joined_at: number }>()).results;
    return json(rows.map((r) => ({ diaryId: r.diary_id, joinedAt: r.joined_at })));
  }

  // ---- GET /v3/diaries/:id — the turn-order/meta source of truth --------
  const idMatch = path.match(/^\/v3\/diaries\/([^/]+)$/);
  if (idMatch && request.method === "GET") {
    const diaryId = idMatch[1];
    const result = await requireMember(env, diaryId, auth.accountId);
    if (result instanceof Response) return result;
    const { meta } = result;
    const out: Record<string, unknown> = {
      diaryId: meta.diaryId, ownerAccountId: meta.ownerAccountId, members: meta.members,
      holderIndex: meta.holderIndex, seq: meta.seq, state: meta.state, keyEpoch: meta.keyEpoch, metaCipher: meta.metaCipher,
    };
    if (meta.ownerAccountId === auth.accountId) out.inviteCode = meta.inviteCode;
    return json(out);
  }

  // ---- POST /v3/diaries/:id/join — link join (id known, code carried) ---
  const joinLinkMatch = path.match(/^\/v3\/diaries\/([^/]+)\/join$/);
  if (joinLinkMatch && request.method === "POST") {
    const diaryId = joinLinkMatch[1];
    if (!(await diaryExistsInD1(db, diaryId))) return json({ error: "not_found" }, 404);
    let body: { inviteCode?: unknown } | null;
    try { body = JSON.parse((await request.text()) || "null"); } catch { body = null; }
    const normalized = typeof body?.inviteCode === "string" ? normalizeAccountId(body.inviteCode) : null;
    if (!normalized) return failJoinCode(env, auth.accountId);
    const metaResp = await doCall(env, diaryId, "/meta");
    if (!metaResp.ok) return json({ error: "not_found" }, 404);
    const meta = await metaResp.json() as DiaryMeta;
    if (meta.inviteCode !== normalized) return failJoinCode(env, auth.accountId);
    return performJoin(env, diaryId, auth.accountId);
  }

  // ---- POST /v3/diaries/join — code-only join (id resolved via D1) ------
  if (path === "/v3/diaries/join" && request.method === "POST") {
    let body: { inviteCode?: unknown } | null;
    try { body = JSON.parse((await request.text()) || "null"); } catch { body = null; }
    const normalized = typeof body?.inviteCode === "string" ? normalizeAccountId(body.inviteCode) : null;
    if (!normalized) return failJoinCode(env, auth.accountId);
    const row = await db.prepare("SELECT diary_id FROM diary_invites WHERE invite_code = ?1").bind(normalized).first<{ diary_id: string }>();
    if (!row) return failJoinCode(env, auth.accountId);
    return performJoin(env, row.diary_id, auth.accountId);
  }

  // ---- POST /v3/diaries/:id/leave ---------------------------------------
  const leaveMatch = path.match(/^\/v3\/diaries\/([^/]+)\/leave$/);
  if (leaveMatch && request.method === "POST") {
    const diaryId = leaveMatch[1];
    if (!(await diaryExistsInD1(db, diaryId))) return json({ error: "not_found" }, 404);
    const leaveResp = await doCall(env, diaryId, "/leave", { method: "POST", body: JSON.stringify({ accountId: auth.accountId }) });
    if (!leaveResp.ok) return json(await leaveResp.json(), leaveResp.status);
    try {
      await db.prepare("DELETE FROM diary_members WHERE account_id = ?1 AND diary_id = ?2").bind(auth.accountId, diaryId).run();
    } catch (e) {
      console.error("diary leave: D1 write failed", String(e));
      return json({ error: "d1_error" }, 500);
    }
    return new Response(null, { status: 204 });
  }

  // ---- POST /v3/diaries/:id/close (owner-only) --------------------------
  const closeMatch = path.match(/^\/v3\/diaries\/([^/]+)\/close$/);
  if (closeMatch && request.method === "POST") {
    const diaryId = closeMatch[1];
    if (!(await diaryExistsInD1(db, diaryId))) return json({ error: "not_found" }, 404);
    const closeResp = await doCall(env, diaryId, "/close", { method: "POST", body: JSON.stringify({ accountId: auth.accountId }) });
    if (!closeResp.ok) return json(await closeResp.json(), closeResp.status);
    return new Response(null, { status: 204 });
  }

  // ---- POST /v3/diaries/:id/invite/reset (owner-only) --------------------
  const resetMatch = path.match(/^\/v3\/diaries\/([^/]+)\/invite\/reset$/);
  if (resetMatch && request.method === "POST") {
    const diaryId = resetMatch[1];
    if (!(await diaryExistsInD1(db, diaryId))) return json({ error: "not_found" }, 404);
    const resetResp = await doCall(env, diaryId, "/invite/reset", { method: "POST", body: JSON.stringify({ accountId: auth.accountId }) });
    if (!resetResp.ok) return json(await resetResp.json(), resetResp.status);
    const { inviteCode, previousCode } = await resetResp.json() as { inviteCode: string; previousCode: string };
    try {
      await db.batch([
        db.prepare("DELETE FROM diary_invites WHERE invite_code = ?1").bind(previousCode),
        db.prepare("INSERT OR IGNORE INTO diary_invites (invite_code, diary_id) VALUES (?1, ?2)").bind(inviteCode, diaryId),
      ]);
    } catch (e) {
      console.error("diary invite reset: D1 write failed", String(e));
      return json({ error: "d1_error" }, 500);
    }
    return json({ inviteCode });
  }

  // ---- .../events (GET list, POST append) --------------------------------
  const eventsMatch = path.match(/^\/v3\/diaries\/([^/]+)\/events$/);
  if (eventsMatch && request.method === "GET") {
    const diaryId = eventsMatch[1];
    const result = await requireMember(env, diaryId, auth.accountId);
    if (result instanceof Response) return result;
    const since = url.searchParams.get("since") ?? "0";
    const limit = url.searchParams.get("limit") ?? "100";
    const resp = await doCall(env, diaryId, `/events?since=${encodeURIComponent(since)}&limit=${encodeURIComponent(limit)}`);
    return json(await resp.json(), resp.status);
  }
  if (eventsMatch && request.method === "POST") {
    const diaryId = eventsMatch[1];
    if (!(await diaryExistsInD1(db, diaryId))) return json({ error: "not_found" }, 404);
    const raw = await request.text();
    if (raw.length > MAX_EVENT_BODY_BYTES) return json({ error: "too_large" }, 413);
    let body: { eventId?: unknown; type?: unknown; refSeq?: unknown; payloadCipher?: unknown } | null;
    try { body = JSON.parse(raw); } catch { body = null; }
    if (!body || typeof body.eventId !== "string" || typeof body.type !== "string") return json({ error: "missing_fields" }, 400);
    if (body.refSeq !== undefined && typeof body.refSeq !== "number") return json({ error: "bad_ref" }, 400);
    if (body.payloadCipher !== undefined && typeof body.payloadCipher !== "string") return json({ error: "bad_payload" }, 400);
    const resp = await doCall(env, diaryId, "/events", {
      method: "POST",
      body: JSON.stringify({ accountId: auth.accountId, eventId: body.eventId, type: body.type, refSeq: body.refSeq, payloadCipher: body.payloadCipher }),
    });
    return json(await resp.json(), resp.status);
  }

  // ---- POST /v3/diaries/:id/request-key ----------------------------------
  const reqKeyMatch = path.match(/^\/v3\/diaries\/([^/]+)\/request-key$/);
  if (reqKeyMatch && request.method === "POST") {
    const diaryId = reqKeyMatch[1];
    const result = await requireMember(env, diaryId, auth.accountId);
    if (result instanceof Response) return result;
    const allowed = await bumpQuota(env.V2_STORE, `diary-keyreq:${auth.accountId}:${diaryId}:${hourKey()}`, REQUEST_KEY_LIMIT_PER_HOUR, 2 * 3600);
    if (!allowed) return json({ error: "rate_limited" }, 429);
    // Task 1 sends no pushes yet — a later task fans out a silent
    // diaryKeyRequest to the diary's other members here.
    return new Response(null, { status: 204 });
  }

  // ---- POST /v3/diaries/:id/events/:seq/report -----------------------
  const reportMatch = path.match(/^\/v3\/diaries\/([^/]+)\/events\/(\d+)\/report$/);
  if (reportMatch && request.method === "POST") {
    const diaryId = reportMatch[1];
    const seq = parseInt(reportMatch[2], 10);
    const result = await requireMember(env, diaryId, auth.accountId);
    if (result instanceof Response) return result;
    const eventResp = await doCall(env, diaryId, `/event/${seq}`);
    if (!eventResp.ok) return json({ error: "not_found" }, 404);
    const event = await eventResp.json() as DiaryEvent;

    const raw = await request.text();
    if (raw.length > MAX_REPORT_BODY_BYTES) return json({ error: "too_large" }, 413);
    let body: { reason?: unknown; excerpt?: unknown } | null;
    try { body = JSON.parse(raw || "null"); } catch { body = null; }
    if (!body || typeof body.reason !== "string" || !["spam", "harassment", "other"].includes(body.reason)) return json({ error: "invalid_report" }, 400);
    let excerpt: string | null = null;
    if (body.excerpt !== undefined && body.excerpt !== null) {
      if (typeof body.excerpt !== "string" || Array.from(body.excerpt).length > NOTE_LIMITS.excerptMaxChars) return json({ error: "invalid_report" }, 400);
      excerpt = body.excerpt;
    }
    if (!(await bumpQuota(env.V2_STORE, `report-quota:${auth.accountId}:${dayKey()}`, NOTE_LIMITS.reportsPerDay, 2 * 86400))) return json({ error: "rate_limited" }, 429);

    const sh = await senderHash(env.TOKEN_SECRET, event.authorAccountId);
    const reportId = ulid();
    try {
      await db.prepare(
        "INSERT INTO reports (id, reporter_account_id, sender_hash, inbox_item_id, diary_id, diary_seq, reason, excerpt, created_at) VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7, ?8)",
      ).bind(reportId, auth.accountId, sh, diaryId, seq, body.reason, excerpt, Date.now()).run();
    } catch (e) {
      console.error("diary report: D1 write failed", String(e));
      return json({ error: "d1_error" }, 500);
    }
    return json({ id: reportId }, 201);
  }

  return null;
}
