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
import { MAX_MEMBERS } from "./diaryRoom";
import type { DiaryEvent, DiaryMeta } from "./diaryRoom";

export interface DiaryAuth { deviceId: string; accountId: string }
export interface DiaryRouteDeps { push: PushDeps }

const DIARY_LIMIT_PER_ACCOUNT = 20;
const JOIN_FAIL_LIMIT_PER_HOUR = 10;
const REQUEST_KEY_LIMIT_PER_HOUR = 6;
const MAX_CREATE_BODY_BYTES = 4 * 1024;
const MAX_EVENT_BODY_BYTES = 96 * 1024;
const MAX_REPORT_BODY_BYTES = 8 * 1024;
const MAX_INVITE_BIND_ATTEMPTS = 5;

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

/**
 * Shared tail of both join routes once `diaryId` + a normalized (but not
 * yet verified) invite code are known. Order matters: an already-current
 * member bypasses every other check (idempotent re-join needs no fresh
 * authorization); otherwise the code is checked against the DO's own
 * `meta.inviteCode` (D1's `diary_invites` only ever resolves a code to a
 * diaryId — it is never trusted as proof the code is still valid), then
 * closed/full-members, and the caller's own 20-diary cap LAST — so a
 * caller already at the cap still gets `diary_closed`/`diary_full_members`
 * for a diary that is actually closed/full, rather than a misleading
 * `diary_limit`. The DO's own `/join` re-validates code/closed/full
 * authoritatively regardless (closes the race window between this preflight
 * read and the mutating call below).
 */
async function performJoin(env: Env, diaryId: string, accountId: string, inviteCode: string): Promise<Response> {
  const db = env.ACCOUNTS_DB;
  const metaResp = await doCall(env, diaryId, "/meta");
  if (!metaResp.ok) return json({ error: "not_found" }, 404);
  const meta = await metaResp.json() as DiaryMeta;
  if (!meta.members.includes(accountId)) {
    if (meta.inviteCode !== inviteCode) return failJoinCode(env, accountId);
    if (meta.state === "closed") return json({ error: "diary_closed" }, 403);
    if (meta.members.length >= MAX_MEMBERS) return json({ error: "diary_full_members" }, 409);
    if (!(await underDiaryLimit(db, accountId, diaryId))) return json({ error: "diary_limit" }, 409);
  }

  const joinResp = await doCall(env, diaryId, "/join", { method: "POST", body: JSON.stringify({ accountId, inviteCode }) });
  if (joinResp.status === 403) {
    const errBody = await joinResp.json() as { error?: string };
    // A race between our preflight read above and this call (e.g. a
    // concurrent invite/reset) — route it through the same rate-limited
    // path as a code caught at preflight, rather than a bare pass-through.
    if (errBody.error === "bad_code") return failJoinCode(env, accountId);
    return json(errBody, 403);
  }
  if (!joinResp.ok) return json(await joinResp.json(), joinResp.status);
  const { added, meta: newMeta } = await joinResp.json() as { added: boolean; meta: DiaryMeta };
  try {
    await db.prepare("INSERT OR IGNORE INTO diary_members (account_id, diary_id, joined_at) VALUES (?1, ?2, ?3)")
      .bind(accountId, diaryId, Date.now()).run();
  } catch (e) {
    console.error("diary join: D1 write failed", String(e));
    return json({ error: "d1_error" }, 500);
  }
  return json(
    { diaryId, members: newMeta.members, holderIndex: newMeta.holderIndex, ownerAccountId: newMeta.ownerAccountId, state: newMeta.state, seq: newMeta.seq, metaCipher: newMeta.metaCipher },
    added ? 201 : 200,
  );
}

/** Ask the DO to mint a fresh invite code (updating its own `meta.inviteCode`), returning the new code. */
async function regenerateInviteCode(env: Env, diaryId: string, ownerAccountId: string): Promise<string> {
  const r = await doCall(env, diaryId, "/invite/reset", { method: "POST", body: JSON.stringify({ accountId: ownerAccountId }) });
  const { inviteCode } = await r.json() as { inviteCode: string };
  return inviteCode;
}

/**
 * Bind `code → diaryId` in D1, verifying the row actually resolves to THIS
 * diary — `INSERT OR IGNORE` silently no-ops on a primary-key collision
 * with a DIFFERENT diary's code (astronomically unlikely with 8 random
 * chars from a 32-symbol alphabet, but checked rather than assumed: the
 * alternative is a diary permanently stuck sharing another diary's invite
 * row). On a genuine collision, mints a fresh code via `regenerate` (which
 * also updates the DO's own `meta.inviteCode`, keeping D1 and the DO in
 * sync) and retries, up to `MAX_INVITE_BIND_ATTEMPTS` times.
 */
async function bindInviteCode(env: Env, diaryId: string, initialCode: string, regenerate: () => Promise<string>): Promise<{ code: string } | Response> {
  const db = env.ACCOUNTS_DB;
  let code = initialCode;
  for (let attempt = 0; attempt < MAX_INVITE_BIND_ATTEMPTS; attempt++) {
    try {
      await db.prepare("INSERT OR IGNORE INTO diary_invites (invite_code, diary_id) VALUES (?1, ?2)").bind(code, diaryId).run();
      const row = await db.prepare("SELECT diary_id FROM diary_invites WHERE invite_code = ?1").bind(code).first<{ diary_id: string }>();
      if (row?.diary_id === diaryId) return { code };
    } catch (e) {
      console.error("diary invite bind: D1 write failed", String(e));
      return json({ error: "d1_error" }, 500);
    }
    code = await regenerate();
  }
  return json({ error: "invite_code_collision" }, 500);
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
      await db.prepare("INSERT OR IGNORE INTO diary_members (account_id, diary_id, joined_at) VALUES (?1, ?2, ?3)")
        .bind(auth.accountId, diaryId, Date.now()).run();
    } catch (e) {
      console.error("diary create: D1 write failed", String(e));
      return json({ error: "d1_error" }, 500);
    }
    const bound = await bindInviteCode(env, diaryId, meta.inviteCode, () => regenerateInviteCode(env, diaryId, auth.accountId));
    if (bound instanceof Response) return bound;
    return json({ diaryId, inviteCode: bound.code }, isNew ? 201 : 200);
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
    return performJoin(env, diaryId, auth.accountId, normalized);
  }

  // ---- POST /v3/diaries/join — code-only join (id resolved via D1, code verified against the DO) ------
  if (path === "/v3/diaries/join" && request.method === "POST") {
    let body: { inviteCode?: unknown } | null;
    try { body = JSON.parse((await request.text()) || "null"); } catch { body = null; }
    const normalized = typeof body?.inviteCode === "string" ? normalizeAccountId(body.inviteCode) : null;
    if (!normalized) return failJoinCode(env, auth.accountId);
    const row = await db.prepare("SELECT diary_id FROM diary_invites WHERE invite_code = ?1").bind(normalized).first<{ diary_id: string }>();
    if (!row) return failJoinCode(env, auth.accountId);
    return performJoin(env, row.diary_id, auth.accountId, normalized);
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
      await db.prepare("DELETE FROM diary_invites WHERE invite_code = ?1").bind(previousCode).run();
    } catch (e) {
      console.error("diary invite reset: D1 delete failed", String(e));
      return json({ error: "d1_error" }, 500);
    }
    const bound = await bindInviteCode(env, diaryId, inviteCode, () => regenerateInviteCode(env, diaryId, auth.accountId));
    if (bound instanceof Response) return bound;
    return json({ inviteCode: bound.code });
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
    if (!resp.ok) return json(await resp.json(), resp.status);
    // The DO's success body also carries `event`/`meta` (used internally,
    // e.g. by diary-room.spec.ts driving the DO directly) — `meta` in
    // particular carries `inviteCode`, which must never reach every other
    // member's device just because they posted an event. Project down to
    // exactly the spec's §2.3 response shape.
    const { seq, holderIndex } = await resp.json() as { seq: number; holderIndex: number };
    return json({ seq, holderIndex }, resp.status);
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
