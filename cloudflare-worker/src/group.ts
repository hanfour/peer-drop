// Group chat room server side: the /v3/groups* HTTP routes in front of the
// GroupRoom Durable Object (./groupRoom.ts). Everything here is
// ciphertext-only — `metaCipher`, wraps and public keys are opaque to it.
//
// WHO THE CALLER IS. `deps.authorize` (index.ts authorizeGroupCaller) yields
// the authenticated deviceId, the accountId the device is signed in to (or
// null) and the lane (Bearer / key). The `Caller` handed to the DO is built
// ONLY from that plus the claimed `X-Group-Member-Id` — never from anything
// else the client sends — and always carries the accountId when there is
// one, even for an anonymous-member action, because the DO checks the ban
// list against every identity the caller holds. An anonymous identity is
// Bearer-only (Ruling 5): `as:"anon"` joins are refused here on the key
// lane, and an existing anonymous member's requests are refused by the DO
// (it sees `lane`).
//
// D1 (`group_members` / `group_invites`) is only an index: "which groups is
// this account in" (the 20-group cap, GET /v3/groups) and "which group does
// this invite code name". Anonymous members never touch D1. Ordering rule:
// the DO is written FIRST and D1 after it, so a D1 failure can only leave a
// member missing from the index — never an account indexed into a group it
// never joined; every create/join re-runs idempotently and repairs D1 with
// INSERT OR IGNORE. Removals go the same way (DO, then D1 DELETE).
//
// WIPED IDS (Ruling 11). When the last member leaves, the DO deletes
// everything, and a later /init for that id would silently create a brand
// new room under an id old invite links and clients still remember. So the
// route keeps a permanent KV tombstone `group-gone:<groupId>` (written
// before the D1 rows go), refuses to create a tombstoned id (409
// group_exists), and repairs a half-finished wipe (D1 rows still present,
// DO empty) whenever it sees one at leave or create.
//
// PRIVACY: never log ids, codes, keys, signatures or ciphertext — only fixed
// strings plus String(e) (same as diary.ts).
import type { Env, GroupAuth } from "./index";
import { bumpQuota, dayKey, json } from "./notes";
import type { PushDeps } from "./notes";
import { generateAccountId, normalizeAccountId } from "./account";
import { GROUP_LIMITS, GROUP_PUSH } from "./groupRoom";
import type { Caller, GroupMember, PushRecipient } from "./groupRoom";
import { decodeB64, decodedByteLength, isValidGroupId, isValidMemberId, memberKeyMessage, sha256Hex, verifyAccountSig, verifyAccountSigs, wrapMessage } from "./groupSig";
import { deliverGroupPush, errName } from "./groupPush";

/**
 * `waitUntil` (the Worker's ctx.waitUntil) runs pushes after the response;
 * without it (direct calls in tests) they are awaited inline.
 */
export interface GroupRouteDeps { push: PushDeps; authorize: (r: Request) => Promise<GroupAuth | null | "unavailable">; waitUntil?: (p: Promise<unknown>) => void }

const GROUP_LIMIT_PER_ACCOUNT = 20;
const GROUP_CREATE_LIMIT_PER_DAY = 20;
const ANON_JOIN_LIMIT_PER_DAY = 20;
const JOIN_FAIL_LIMIT_PER_HOUR = 10;
const MAX_CREATE_BODY_BYTES = 600 * 1024;
const MAX_SMALL_BODY_BYTES = 4 * 1024;
const MAX_INVITE_BIND_ATTEMPTS = 5;
const MAX_EVENT_BODY_BYTES = 16 * 1024;
const MAX_META_BODY_BYTES = 600 * 1024;
const MAX_ROTATE_BODY_BYTES = 640 * 1024;
const MAX_KEYS_BODY_BYTES = 32 * 1024;
const KEY_REQUEST_LIMIT_PER_HOUR = 6;
/**
 * Joins into ONE room per identity (account, else device hash) per hour —
 * fresh seats and Ruling-12 takeovers alike. Each one writes leave/join
 * events and fires a key-request push, so leave/join churn is capped here.
 */
const ROOM_JOIN_LIMIT_PER_HOUR = 6;
/**
 * Key-request pushes (join-time + explicit) per identity per room per hour:
 * the per-seat cap of 6 alone would refill with every new seat.
 */
const KEY_REQUEST_IDENTITY_LIMIT_PER_HOUR = 12;
const MAX_TICKET_LEN = 64;
/** wrapMessage encodes the epoch as UInt32BE: anything larger would alias a smaller epoch's signature. */
const MAX_EPOCH = 0xFFFF_FFFF;
const TOMBSTONE_PREFIX = "group-gone:";

/**
 * Every error code the GroupRoom DO answers, and the HTTP status the route
 * gives it. Only the code (plus `epoch` for stale_epoch and `memberIds` for
 * members_changed) is passed on; anything else in a DO body is dropped.
 */
export const DO_ERROR_STATUS: Readonly<Record<string, number>> = {
  bad_request: 400, bad_event_id: 400, bad_payload: 400, bad_wrap: 400, unknown_member: 400, kick_self: 400,
  bearer_required: 401,
  identity_mismatch: 403, account_required: 403, not_keyed: 403, awaiting_key: 403, not_owner: 403,
  not_member: 403, group_closed: 403, banned: 403, bad_code: 403, denied: 403,
  not_found: 404,
  event_id_taken: 409, stale_epoch: 409, members_changed: 409, group_exists: 409, group_full_members: 409, member_id_taken: 409,
  too_large: 413,
  rate_limited: 429,
  busy: 503,
};

/** Maps a non-2xx DO response to the client response (unknown → 502, never a bare pass-through). */
export async function fromDo(resp: Response): Promise<Response> {
  let body: Record<string, unknown> | null = null;
  try { body = await resp.json() as Record<string, unknown>; } catch { body = null; }
  const code = body && typeof body.error === "string" ? body.error : null;
  if (!code || !Object.hasOwn(DO_ERROR_STATUS, code)) {
    console.error("group: unexpected room response", resp.status);
    return json({ error: "room_error" }, 502);
  }
  const out: Record<string, unknown> = { error: code };
  if (code === "stale_epoch" && typeof body!.epoch === "number") out.epoch = body!.epoch;
  if (code === "members_changed" && Array.isArray(body!.memberIds)) out.memberIds = body!.memberIds;
  return json(out, DO_ERROR_STATUS[code]);
}

/** UTC yyyyMMddHH — the join-fail bucket. */
function hourKey(now: number = Date.now()): string {
  const d = new Date(now);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}${pad(d.getUTCHours())}`;
}

/**
 * Gate for every route on an existing id: 404 without waking the DO for an
 * id nobody created. Either table: `group_invites` outlives the last account
 * member (a room of anonymous members only), `group_members` is written
 * first on create.
 */
export async function groupExistsInD1(db: D1Database, groupId: string): Promise<boolean> {
  const row = await db.prepare(
    "SELECT 1 AS x FROM group_members WHERE group_id = ?1 UNION SELECT 1 AS x FROM group_invites WHERE group_id = ?2 LIMIT 1",
  ).bind(groupId, groupId).first();
  return !!row;
}

/** Create / account join: an account already in this group skips its own cap. */
export async function underGroupLimit(db: D1Database, accountId: string, groupId: string): Promise<boolean> {
  const already = await db.prepare("SELECT 1 AS x FROM group_members WHERE account_id = ?1 AND group_id = ?2").bind(accountId, groupId).first();
  if (already) return true;
  const row = await db.prepare("SELECT COUNT(*) AS n FROM group_members WHERE account_id = ?1").bind(accountId).first<{ n: number }>();
  return (row?.n ?? 0) < GROUP_LIMIT_PER_ACCOUNT;
}

const keyRequestIdentityKey = (groupId: string, identity: string) => `group-keyreq-who:${groupId}:${identity}:${hourKey()}`;

/** The per-caller key for the wrong-code limit: the account if signed in, else the device's hash. */
async function failKeyOf(auth: GroupAuth): Promise<string> {
  return auth.accountId ?? `dev:${await sha256Hex(auth.deviceId)}`;
}

/** A wrong/malformed invite code: 10 an hour per caller, then 429. */
export async function failJoinCode(env: Env, key: string): Promise<Response> {
  const allowed = await bumpQuota(env.V2_STORE, `group-join-fail:${key}:${hourKey()}`, JOIN_FAIL_LIMIT_PER_HOUR, 2 * 3600);
  if (!allowed) return json({ error: "rate_limited" }, 429);
  return json({ error: "bad_code" }, 403);
}

/** One call to the room: always a fresh internal Request, never the client's. */
export async function doCall(env: Env, groupId: string, path: string, body: unknown): Promise<Response> {
  const stub = env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(groupId));
  return stub.fetch(new Request(`https://group${path}`, { method: "POST", body: JSON.stringify(body) }));
}

/** The DO-side caller: authenticated identity + the claimed X-Group-Member-Id. */
export function callerFor(auth: GroupAuth, request: Request): Caller | Response {
  const memberId = request.headers.get("X-Group-Member-Id");
  if (!memberId || !isValidMemberId(memberId)) return json({ error: "missing_fields" }, 400);
  return { memberId, accountId: auth.accountId, deviceId: auth.deviceId, lane: auth.lane };
}

/**
 * Bind `code → groupId` in D1, checking the row really names THIS group (a
 * primary-key collision with another group's code is a silent no-op under
 * INSERT OR IGNORE); on a collision mint a fresh code in the DO and retry.
 */
export async function bindGroupInviteCode(env: Env, groupId: string, initialCode: string, regenerate: () => Promise<string | null>): Promise<{ code: string } | Response> {
  const db = env.ACCOUNTS_DB;
  let code: string | null = initialCode;
  for (let attempt = 0; attempt < MAX_INVITE_BIND_ATTEMPTS && code; attempt++) {
    try {
      await db.prepare("INSERT OR IGNORE INTO group_invites (invite_code, group_id) VALUES (?1, ?2)").bind(code, groupId).run();
      const row = await db.prepare("SELECT group_id FROM group_invites WHERE invite_code = ?1").bind(code).first<{ group_id: string }>();
      if (row?.group_id === groupId) return { code };
    } catch (e) {
      console.error("group invite bind: D1 write failed", String(e));
      return json({ error: "d1_error" }, 500);
    }
    code = await regenerate();
  }
  return json({ error: "invite_code_collision" }, 500);
}

/** Ask the DO for a fresh invite code as `caller` (the owner). */
async function regenerateInvite(env: Env, groupId: string, caller: Caller): Promise<string | null> {
  const r = await doCall(env, groupId, "/invite/reset", { caller });
  if (!r.ok) return null;
  return (await r.json() as { inviteCode: string }).inviteCode;
}

const tombstoneKey = (groupId: string) => `${TOMBSTONE_PREFIX}${groupId}`;

async function isTombstoned(env: Env, groupId: string): Promise<boolean> {
  return (await env.V2_STORE.get(tombstoneKey(groupId))) !== null;
}

/** The room is wiped: tombstone the id (first), then drop its D1 index rows. Throws on failure. */
async function markGone(env: Env, groupId: string): Promise<void> {
  await env.V2_STORE.put(tombstoneKey(groupId), "1");
  await env.ACCOUNTS_DB.batch([
    env.ACCOUNTS_DB.prepare("DELETE FROM group_members WHERE group_id = ?1").bind(groupId),
    env.ACCOUNTS_DB.prepare("DELETE FROM group_invites WHERE group_id = ?1").bind(groupId),
  ]);
}

/**
 * Runs `task` after the response (waitUntil) or, with no waitUntil, inline.
 * Never rejects: a failure is logged as a fixed label + the error's class.
 */
async function inBackground(deps: GroupRouteDeps, label: string, task: () => Promise<void>): Promise<void> {
  const p = task().catch((e) => { console.error(label, errName(e)); });
  if (deps.waitUntil) deps.waitUntil(p);
  else await p;
}

/**
 * Brings the D1 row (accountId, groupId) in line with the room: DELETE it
 * first, THEN ask the room whether the account still holds a seat and put
 * the row back if so. In that order a join racing a leave/kick can't be
 * lost: a join always INSERTs after its DO write, so either its INSERT
 * lands after this DELETE, or this check already sees the seat. (Checking
 * first and deleting after could delete a just-rejoined account's row.)
 * Throws on a D1 or room error.
 */
export async function reconcileAccountIndex(env: Env, groupId: string, accountId: string): Promise<void> {
  const db = env.ACCOUNTS_DB;
  await db.prepare("DELETE FROM group_members WHERE account_id = ?1 AND group_id = ?2").bind(accountId, groupId).run();
  const r = await doCall(env, groupId, "/account-member", { accountId });
  if (!r.ok) throw new Error("account-member check failed");
  const { member } = await r.json() as { member: boolean };
  if (member) {
    await db.prepare("INSERT OR IGNORE INTO group_members (account_id, group_id, joined_at) VALUES (?1, ?2, ?3)").bind(accountId, groupId, Date.now()).run();
  }
}

/**
 * The room said this account isn't (or is no longer) in it while D1 may
 * still list the group for it — a kick/leave whose DELETE failed, a retry
 * that could no longer name the account. Repair when D1 has the row. A
 * Ruling-12 takeover's old device lands here too; reconcile keeps the row.
 * Best effort: never changes the response.
 */
async function reconcileIfIndexed(env: Env, groupId: string, accountId: string): Promise<void> {
  try {
    const row = await env.ACCOUNTS_DB.prepare("SELECT 1 AS x FROM group_members WHERE account_id = ?1 AND group_id = ?2").bind(accountId, groupId).first();
    if (row) await reconcileAccountIndex(env, groupId, accountId);
  } catch (e) {
    console.error("group: index repair failed", String(e));
  }
}

async function readSmallBody(request: Request): Promise<Record<string, unknown> | Response> {
  return readJsonBody(request, MAX_SMALL_BODY_BYTES);
}

/** A JSON object body of at most `max` characters (413 above, 400 if not an object). */
async function readJsonBody(request: Request, max: number): Promise<Record<string, unknown> | Response> {
  const raw = await request.text();
  if (raw.length > max) return json({ error: "too_large" }, 413);
  let body: unknown;
  try { body = JSON.parse(raw || "null"); } catch { body = null; }
  if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "missing_fields" }, 400);
  return body as Record<string, unknown>;
}

const isB64Of = (v: unknown, n: number): v is string => typeof v === "string" && decodedByteLength(v) === n;

interface WrapIn { memberId: string; wrapped: string; sig: string }

/**
 * A wraps array as the room takes it: at most 50, distinct valid memberIds
 * (else 400 bad_request), each `wrapped` 92 bytes and `sig` 64 bytes of
 * strict base64 (else 400 bad_wrap) — checked here because the signatures
 * are verified before the room sees the request.
 */
function parseWrapsInput(v: unknown): WrapIn[] | Response {
  if (!Array.isArray(v) || v.length > GROUP_LIMITS.maxMembers) return json({ error: "bad_request" }, 400);
  const seen = new Set<string>();
  const out: WrapIn[] = [];
  let shapeOk = true;
  for (const w of v) {
    if (!w || typeof w !== "object") return json({ error: "bad_request" }, 400);
    const { memberId, wrapped, sig } = w as Record<string, unknown>;
    if (!isValidMemberId(memberId) || seen.has(memberId)) return json({ error: "bad_request" }, 400);
    seen.add(memberId);
    if (!isB64Of(wrapped, GROUP_LIMITS.wrappedBytes) || !isB64Of(sig, GROUP_LIMITS.sigBytes)) { shapeOk = false; continue; }
    out.push({ memberId, wrapped, sig });
  }
  return shapeOk ? out : json({ error: "bad_wrap" }, 400);
}

const isEpoch = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0 && v <= MAX_EPOCH;

/**
 * Ruling 6 for PUT /keys and POST /rotate: every wrap must be signed by the
 * CALLER's account over wrapMessage(groupId, epoch, target, wrapper = the
 * caller's memberId — what the room records as wrappedBy — , wrapped).
 */
function wrapsSignedByCaller(env: Env, groupId: string, caller: Caller, epoch: number, wraps: WrapIn[]): Promise<boolean> {
  return verifyAccountSigs(env.ACCOUNTS_DB, caller.accountId!, wraps.map((w) => ({
    message: wrapMessage(groupId, epoch, w.memberId, caller.memberId, decodeB64(w.wrapped)!),
    sig: w.sig,
  })));
}

/** `?since=` / `?limit=`: absent, or a plain non-negative integer. */
function parseListQuery(url: URL): { since?: number; limit?: number } | Response {
  const out: { since?: number; limit?: number } = {};
  for (const k of ["since", "limit"] as const) {
    const v = url.searchParams.get(k);
    if (v === null) continue;
    if (!/^\d{1,15}$/.test(v)) return json({ error: "bad_request" }, 400);
    out[k] = Number(v);
  }
  return out;
}

// ---- create ---------------------------------------------------------------

async function createGroup(request: Request, env: Env, auth: GroupAuth): Promise<Response> {
  const db = env.ACCOUNTS_DB;
  // 1. Parse and validate everything before any side effect.
  const raw = await request.text();
  if (raw.length > MAX_CREATE_BODY_BYTES) return json({ error: "too_large" }, 413);
  if (!auth.accountId) return json({ error: "account_required" }, 403);
  const accountId = auth.accountId;
  let b: Record<string, unknown> | null;
  try { b = JSON.parse(raw); } catch { b = null; }
  const wrap = b && typeof b.ownerWrap === "object" && b.ownerWrap ? b.ownerWrap as Record<string, unknown> : null;
  if (!b || typeof b.groupId !== "string" || typeof b.memberId !== "string" || typeof b.pubKey !== "string"
    || typeof b.pubKeySig !== "string" || !wrap || typeof wrap.wrapped !== "string" || typeof wrap.sig !== "string"
    || typeof b.metaCipher !== "string") {
    return json({ error: "missing_fields" }, 400);
  }
  if (!isValidGroupId(b.groupId) || !isValidMemberId(b.memberId)) return json({ error: "invalid_id" }, 400);
  const joinPolicy = b.joinPolicy ?? "accountOnly";
  if (joinPolicy !== "accountOnly" && joinPolicy !== "anonymousAllowed") return json({ error: "bad_request" }, 400);
  if (!isB64Of(b.pubKey, GROUP_LIMITS.pubKeyBytes) || !isB64Of(b.pubKeySig, GROUP_LIMITS.sigBytes)
    || !isB64Of(wrap.wrapped, GROUP_LIMITS.wrappedBytes) || !isB64Of(wrap.sig, GROUP_LIMITS.sigBytes)) {
    return json({ error: "bad_request" }, 400);
  }
  const metaLen = b.metaCipher.length > 0 ? decodedByteLength(b.metaCipher) : null;
  if (metaLen === null || metaLen === 0) return json({ error: "bad_request" }, 400);
  if (metaLen > GROUP_LIMITS.maxMetaBytes) return json({ error: "too_large" }, 413);
  const groupId = b.groupId, memberId = b.memberId;
  // 2. Signatures (Ruling 6): the owner's room key and its own epoch-1 wrap.
  const keyOk = await verifyAccountSig(db, accountId, memberKeyMessage(groupId, memberId, accountId, decodeB64(b.pubKey)!), b.pubKeySig);
  const wrapOk = keyOk && await verifyAccountSig(db, accountId, wrapMessage(groupId, 1, memberId, memberId, decodeB64(wrap.wrapped)!), wrap.sig);
  if (!keyOk || !wrapOk) return json({ error: "bad_sig" }, 400);

  // 3. A wiped id stays dead (Ruling 11) — also when only the D1 cleanup was lost.
  if (await isTombstoned(env, groupId)) return json({ error: "group_exists" }, 409);
  const caller: Caller = { memberId, accountId, deviceId: auth.deviceId, lane: auth.lane };
  if (await groupExistsInD1(db, groupId)) {
    const probe = await doCall(env, groupId, "/view", { caller });
    if (probe.status === 404) {
      try { await markGone(env, groupId); } catch (e) { console.error("group create: wipe repair failed", String(e)); }
      return json({ error: "group_exists" }, 409);
    }
  }

  // 4. Membership cap, then the daily cost-of-trying quota (same order and
  //    reasons as diary create), and only then the room.
  if (!(await underGroupLimit(db, accountId, groupId))) return json({ error: "group_limit" }, 409);
  if (!(await bumpQuota(env.V2_STORE, `group-create:${accountId}:${dayKey()}`, GROUP_CREATE_LIMIT_PER_DAY, 2 * 86400))) {
    return json({ error: "rate_limited" }, 429);
  }
  const initResp = await doCall(env, groupId, "/init", {
    groupId,
    owner: { memberId, accountId, pubKey: b.pubKey, pubKeySig: b.pubKeySig },
    ownerWrap: { wrapped: wrap.wrapped, sig: wrap.sig },
    metaCipher: b.metaCipher,
    joinPolicy,
    inviteCode: generateAccountId(),
  });
  if (!initResp.ok) return fromDo(initResp);
  const meta = await initResp.json() as { inviteCode: string; ownerMemberId: string | null };
  const isNew = initResp.status === 201;

  // 5. D1 after the DO (idempotent; a resend repairs it).
  try {
    await db.prepare("INSERT OR IGNORE INTO group_members (account_id, group_id, joined_at) VALUES (?1, ?2, ?3)")
      .bind(accountId, groupId, Date.now()).run();
  } catch (e) {
    console.error("group create: D1 write failed", String(e));
    return json({ error: "d1_error" }, 500);
  }
  const ownerCaller: Caller = { ...caller, memberId: meta.ownerMemberId ?? memberId };
  const bound = await bindGroupInviteCode(env, groupId, meta.inviteCode, () => regenerateInvite(env, groupId, ownerCaller));
  if (bound instanceof Response) return bound;
  return json({ groupId, inviteCode: bound.code }, isNew ? 201 : 200);
}

// ---- join -----------------------------------------------------------------

interface JoinInput { memberId: string; pubKey: string; pubKeySig?: string; as: "account" | "anon"; inviteCode: unknown }

/** Validates a join body against the caller's identity; nothing is spent yet. */
async function parseJoin(request: Request, auth: GroupAuth): Promise<JoinInput | Response> {
  const b = await readSmallBody(request);
  if (b instanceof Response) return b;
  if (typeof b.memberId !== "string" || typeof b.pubKey !== "string" || (b.as !== "account" && b.as !== "anon")) return json({ error: "missing_fields" }, 400);
  if (!isValidMemberId(b.memberId)) return json({ error: "invalid_id" }, 400);
  if (!isB64Of(b.pubKey, GROUP_LIMITS.pubKeyBytes)) return json({ error: "bad_request" }, 400);
  if (b.as === "account") {
    if (!auth.accountId) return json({ error: "account_required" }, 403);
    if (typeof b.pubKeySig !== "string") return json({ error: "missing_fields" }, 400);
    if (!isB64Of(b.pubKeySig, GROUP_LIMITS.sigBytes)) return json({ error: "bad_request" }, 400);
    return { memberId: b.memberId, pubKey: b.pubKey, pubKeySig: b.pubKeySig, as: "account", inviteCode: b.inviteCode };
  }
  // Anonymous identity: Bearer lane only (Ruling 5), and no signature to carry.
  if (auth.lane !== "bearer") return json({ error: "bearer_required" }, 401);
  if (b.pubKeySig !== undefined) return json({ error: "bad_request" }, 400);
  return { memberId: b.memberId, pubKey: b.pubKey, as: "anon", inviteCode: b.inviteCode };
}

const normalizeCode = (v: unknown): string | null => (typeof v === "string" && v.length <= 64 ? normalizeAccountId(v) : null);

/**
 * Shared tail of both join routes once the groupId is known. Order: the
 * member-key signature → a dryRun /join (the DO's full check list, bad
 * codes counted) → the caller's own caps LAST (so a capped caller still
 * hears group_full_members / group_closed for a room that really is) → the
 * real /join (which re-checks everything authoritatively) → D1 → key push.
 */
async function performJoin(env: Env, auth: GroupAuth, groupId: string, input: JoinInput, inviteCode: string, deps: GroupRouteDeps): Promise<Response> {
  const db = env.ACCOUNTS_DB;
  const failKey = await failKeyOf(auth);
  if (input.as === "account") {
    const ok = await verifyAccountSig(db, auth.accountId!, memberKeyMessage(groupId, input.memberId, auth.accountId!, decodeB64(input.pubKey)!), input.pubKeySig!);
    if (!ok) return json({ error: "bad_sig" }, 400);
  }
  const caller: Caller = { memberId: input.memberId, accountId: auth.accountId, deviceId: auth.deviceId, lane: auth.lane };
  const member: Partial<GroupMember> = input.as === "account"
    ? { memberId: input.memberId, kind: "account", accountId: auth.accountId!, pubKey: input.pubKey, pubKeySig: input.pubKeySig }
    : { memberId: input.memberId, kind: "anon", deviceId: auth.deviceId, pubKey: input.pubKey };
  const joinBody = { caller, member, inviteCode };

  const dry = await doCall(env, groupId, "/join", { ...joinBody, dryRun: true });
  if (!dry.ok) {
    const err = await fromDo(dry);
    if (dry.status === 403 && (await err.clone().json() as { error: string }).error === "bad_code") return failJoinCode(env, failKey);
    return err;
  }
  if (dry.status === 201) {
    if (input.as === "account" && !(await underGroupLimit(db, auth.accountId!, groupId))) return json({ error: "group_limit" }, 409);
    // Every real join (new seat or takeover) — not an idempotent resend (200).
    if (!(await bumpQuota(env.V2_STORE, `group-join:${groupId}:${failKey}:${hourKey()}`, ROOM_JOIN_LIMIT_PER_HOUR, 2 * 3600))) {
      return json({ error: "rate_limited" }, 429);
    }
    if (input.as === "anon" && !(await bumpQuota(env.V2_STORE, `group-anon-join:${await sha256Hex(auth.deviceId)}:${dayKey()}`, ANON_JOIN_LIMIT_PER_DAY, 2 * 86400))) {
      return json({ error: "rate_limited" }, 429);
    }
  }

  const joinResp = await doCall(env, groupId, "/join", joinBody);
  if (!joinResp.ok) {
    const err = await fromDo(joinResp);
    // A code reset between the dryRun and here: count it like any wrong code.
    if (joinResp.status === 403 && (await err.clone().json() as { error: string }).error === "bad_code") return failJoinCode(env, failKey);
    return err;
  }
  const added = joinResp.status === 201;
  if (input.as === "account") {
    try {
      await db.prepare("INSERT OR IGNORE INTO group_members (account_id, group_id, joined_at) VALUES (?1, ?2, ?3)")
        .bind(auth.accountId, groupId, Date.now()).run();
    } catch (e) {
      console.error("group join: D1 write failed", String(e));
      return json({ error: "d1_error" }, 500);
    }
  }
  // A new seat holds no key yet: silently ask the keyed account members to
  // relay one — within the identity's key-request budget (else skipped; the
  // client can still ask explicitly once the budget frees up).
  if (added && await bumpQuota(env.V2_STORE, keyRequestIdentityKey(groupId, failKey), KEY_REQUEST_IDENTITY_LIMIT_PER_HOUR, 2 * 3600)) {
    await inBackground(deps, "group join: key request push failed", async () => {
      const rk = await doCall(env, groupId, "/request-key", { caller });
      if (!rk.ok) return;
      const { recipients } = await rk.json() as { recipients: PushRecipient[] };
      await deliverGroupPush(env, recipients, GROUP_PUSH.keyRequest(groupId), deps.push);
    });
  }
  const view = await doCall(env, groupId, "/view", { caller });
  if (!view.ok) return fromDo(view);
  const v = await view.json() as { epoch: number; state: string; ownerMemberId: string | null };
  return json({ groupId, memberId: input.memberId, epoch: v.epoch, state: v.state, ownerMemberId: v.ownerMemberId }, added ? 201 : 200);
}

// ---- dispatcher -------------------------------------------------------------

const MEMBER_ROUTES = new Set([
  "GET ", "POST /join", "POST /leave", "POST /kick", "POST /close", "POST /invite/reset",
  "GET /events", "POST /events", "GET /meta", "PUT /meta", "POST /rotate", "GET /keys", "PUT /keys",
  "POST /request-key", "POST /ws-ticket",
]);

/**
 * GET /v3/groups/:id/ws?ticket= — the WebSocket upgrade. Authenticated by
 * the one-time ticket ONLY (no Authorization, no member header: URLSession
 * can't reliably send headers on an upgrade, and a long-lived Bearer must
 * never sit in a URL). The DO gets a brand-new Request carrying nothing but
 * the ticket and a lowercase `Upgrade: websocket` (it compares exactly).
 */
async function upgradeSocket(request: Request, url: URL, env: Env, groupId: string): Promise<Response> {
  if ((request.headers.get("Upgrade") ?? "").toLowerCase() !== "websocket") return json({ error: "bad_request" }, 400);
  if (!isValidGroupId(groupId) || !(await groupExistsInD1(env.ACCOUNTS_DB, groupId))) return json({ error: "not_found" }, 404);
  const ticket = url.searchParams.get("ticket") ?? "";
  if (!ticket || ticket.length > MAX_TICKET_LEN) return json({ error: "denied" }, 403);
  const stub = env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(groupId));
  const resp = await stub.fetch(new Request(`https://group/ws?ticket=${encodeURIComponent(ticket)}`, { headers: { Upgrade: "websocket" } }));
  if (resp.status === 101) return resp;
  return fromDo(resp);
}

/** /v3/groups* — anything unmatched is 404 not_found. */
export async function handleGroupRoute(request: Request, url: URL, path: string, env: Env, deps: GroupRouteDeps): Promise<Response> {
  // The upgrade is ticket-only and must never consult the caller's token.
  const ws = request.method === "GET" ? path.match(/^\/v3\/groups\/([^/]+)\/ws$/) : null;
  if (ws) return upgradeSocket(request, url, env, ws[1]);

  const auth = await deps.authorize(request);
  if (auth === "unavailable") return json({ error: "unavailable" }, 503);
  if (!auth) return json({ error: "Unauthorized" }, 401);
  const db = env.ACCOUNTS_DB;

  if (path === "/v3/groups" && request.method === "POST") return createGroup(request, env, auth);

  if (path === "/v3/groups" && request.method === "GET") {
    if (!auth.accountId) return json({ error: "account_required" }, 403);
    const rows = (await db.prepare("SELECT group_id, joined_at FROM group_members WHERE account_id = ?1 ORDER BY joined_at")
      .bind(auth.accountId).all<{ group_id: string; joined_at: number }>()).results;
    return json(rows.map((r) => ({ groupId: r.group_id, joinedAt: r.joined_at })));
  }

  // Code-only join: the code names the group via D1, the DO verifies it.
  if (path === "/v3/groups/join" && request.method === "POST") {
    const input = await parseJoin(request, auth);
    if (input instanceof Response) return input;
    const code = normalizeCode(input.inviteCode);
    const row = code ? await db.prepare("SELECT group_id FROM group_invites WHERE invite_code = ?1").bind(code).first<{ group_id: string }>() : null;
    if (!code || !row) return failJoinCode(env, await failKeyOf(auth));
    return performJoin(env, auth, row.group_id, input, code, deps);
  }

  const m = path.match(/^\/v3\/groups\/([^/]+)(\/.*)?$/);
  const sub = m?.[2] ?? "";
  if (!m || !MEMBER_ROUTES.has(`${request.method} ${sub}`)) return json({ error: "not_found" }, 404);
  const groupId = m[1];

  // Bodies are read and validated before the existence check wakes nothing.
  const route = `${request.method} ${sub}`;
  let kickTarget: string | null = null;
  let joinInput: JoinInput | null = null;
  /** The validated fields of a content route's body (or query), passed on to the room. */
  let fields: Record<string, unknown> = {};
  let wraps: WrapIn[] = [];
  if (route === "POST /events") {
    const b = await readJsonBody(request, MAX_EVENT_BODY_BYTES);
    if (b instanceof Response) return b;
    if (typeof b.eventId !== "string" || typeof b.epoch !== "number" || typeof b.payloadCipher !== "string") return json({ error: "missing_fields" }, 400);
    fields = { eventId: b.eventId, epoch: b.epoch, payloadCipher: b.payloadCipher };
  } else if (route === "GET /events") {
    const q = parseListQuery(url);
    if (q instanceof Response) return q;
    fields = q;
  } else if (route === "PUT /meta") {
    const b = await readJsonBody(request, MAX_META_BODY_BYTES);
    if (b instanceof Response) return b;
    if (typeof b.eventId !== "string" || typeof b.metaCipher !== "string") return json({ error: "missing_fields" }, 400);
    fields = { eventId: b.eventId, metaCipher: b.metaCipher, joinPolicy: b.joinPolicy, removeAnonymous: b.removeAnonymous };
  } else if (route === "POST /rotate" || route === "PUT /keys") {
    const rotate = route === "POST /rotate";
    const b = await readJsonBody(request, rotate ? MAX_ROTATE_BODY_BYTES : MAX_KEYS_BODY_BYTES);
    if (b instanceof Response) return b;
    if (b.epoch === undefined || b.wraps === undefined || (rotate && (typeof b.eventId !== "string" || typeof b.metaCipher !== "string"))) {
      return json({ error: "missing_fields" }, 400);
    }
    if (!isEpoch(b.epoch)) return json({ error: "bad_request" }, 400);
    const w = parseWrapsInput(b.wraps);
    if (w instanceof Response) return w;
    wraps = w;
    fields = rotate ? { eventId: b.eventId, epoch: b.epoch, metaCipher: b.metaCipher } : { epoch: b.epoch };
  } else if (sub === "/kick") {
    const b = await readSmallBody(request);
    if (b instanceof Response) return b;
    if (typeof b.memberId !== "string") return json({ error: "missing_fields" }, 400);
    if (!isValidMemberId(b.memberId)) return json({ error: "invalid_id" }, 400);
    kickTarget = b.memberId;
  } else if (sub === "/join") {
    const input = await parseJoin(request, auth);
    if (input instanceof Response) return input;
    joinInput = input;
  }

  if (!isValidGroupId(groupId) || !(await groupExistsInD1(db, groupId))) return json({ error: "not_found" }, 404);

  if (joinInput) {
    const code = normalizeCode(joinInput.inviteCode);
    if (!code) return failJoinCode(env, await failKeyOf(auth));
    return performJoin(env, auth, groupId, joinInput, code, deps);
  }

  const caller = callerFor(auth, request);
  if (caller instanceof Response) return caller;
  /** doCall for a member route: a not_member answer repairs a stale D1 row for the caller's account. */
  const call = async (doPath: string, body: unknown): Promise<Response> => {
    const r = await doCall(env, groupId, doPath, body);
    if (r.status === 403 && auth.accountId) {
      const peek = await r.clone().json().catch(() => null) as { error?: unknown } | null;
      if (peek?.error === "not_member") await reconcileIfIndexed(env, groupId, auth.accountId);
    }
    return r;
  };

  if (sub === "") {
    const r = await call("/view", { caller });
    if (!r.ok) return fromDo(r);
    return json(await r.json());
  }

  // ---- content routes (Task 7) ----
  if (route === "GET /events" || route === "GET /keys" || route === "GET /meta") {
    const doPath = route === "GET /events" ? "/events/list" : route === "GET /keys" ? "/keys/mine" : "/meta-cipher";
    const r = await call(doPath, { caller, ...fields });
    if (!r.ok) return fromDo(r);
    return json(await r.json());
  }

  if (route === "POST /events") {
    const r = await call("/events/msg", { caller, ...fields });
    if (!r.ok) return fromDo(r);
    const out = await r.json() as { seq: number; recipients?: PushRecipient[] };
    const recipients = r.status === 201 ? out.recipients ?? [] : [];
    if (recipients.length) {
      await inBackground(deps, "group msg push failed", () => deliverGroupPush(env, recipients, GROUP_PUSH.message(groupId), deps.push));
    }
    // Only the seq: the stored event and the recipient list stay server-side.
    return json({ seq: out.seq }, r.status);
  }

  if (route === "PUT /meta") {
    const r = await call("/meta", { caller, ...fields });
    if (!r.ok) return fromDo(r);
    const out = await r.json() as { seq: number; metaVersion: number };
    return json({ seq: out.seq, metaVersion: out.metaVersion }, r.status);
  }

  if (route === "POST /rotate" || route === "PUT /keys") {
    // Only an account's signature can be checked (Ruling 7); the owner is always one.
    if (!caller.accountId) return json({ error: "account_required" }, 403);
    if (!(await wrapsSignedByCaller(env, groupId, caller, fields.epoch as number, wraps))) return json({ error: "bad_sig" }, 400);
    if (route === "PUT /keys") {
      const r = await call("/keys/put", { caller, epoch: fields.epoch, wraps });
      if (!r.ok) return fromDo(r);
      const out = await r.json() as { written: string[]; skipped: string[] };
      return json({ written: out.written, skipped: out.skipped });
    }
    const r = await call("/rotate", { caller, ...fields, wraps });
    if (!r.ok) return fromDo(r);
    const out = await r.json() as { seq: number; epoch: number };
    return json({ seq: out.seq, epoch: out.epoch }, r.status);
  }

  if (route === "POST /request-key") {
    // The room authorizes first (no writes there), so a stranger claiming a
    // member's id can't spend that member's budget.
    const r = await call("/request-key", { caller });
    if (!r.ok) return fromDo(r);
    const { recipients } = await r.json() as { recipients: PushRecipient[] };
    // Per seat (6) and per identity across seats and join-time requests (12).
    if (!(await bumpQuota(env.V2_STORE, `group-keyreq:${groupId}:${caller.memberId}:${hourKey()}`, KEY_REQUEST_LIMIT_PER_HOUR, 2 * 3600))
      || !(await bumpQuota(env.V2_STORE, keyRequestIdentityKey(groupId, await failKeyOf(auth)), KEY_REQUEST_IDENTITY_LIMIT_PER_HOUR, 2 * 3600))) {
      return json({ error: "rate_limited" }, 429);
    }
    if (recipients.length) {
      await inBackground(deps, "group key request push failed", () => deliverGroupPush(env, recipients, GROUP_PUSH.keyRequest(groupId), deps.push));
    }
    return new Response(null, { status: 204 });
  }

  if (route === "POST /ws-ticket") {
    const r = await call("/ws-ticket", { caller });
    if (!r.ok) return fromDo(r);
    const { ticket } = await r.json() as { ticket: string };
    return json({ ticket, expiresInSeconds: GROUP_LIMITS.ticketTtlMs / 1000 });
  }

  if (sub === "/leave") {
    const r = await call("/leave", { caller });
    if (r.status === 404) {
      // D1 still indexes a room the DO already wiped: finish the wipe.
      try { await markGone(env, groupId); } catch (e) {
        console.error("group leave: wipe repair failed", String(e));
        return json({ error: "d1_error" }, 500);
      }
      return new Response(null, { status: 204 });
    }
    if (!r.ok) return fromDo(r);
    const { remaining, removed } = await r.json() as { remaining: number; removed: { kind: string; accountId?: string } | null };
    try {
      // Last one out: the DO is empty — tombstone the id and drop every D1 row.
      if (remaining === 0) await markGone(env, groupId);
      else if (removed?.kind === "account" && removed.accountId) await reconcileAccountIndex(env, groupId, removed.accountId);
      // Not a member (already gone, or an old Ruling-12 seat): repair a stale row, if any.
      else if (!removed && auth.accountId) await reconcileIfIndexed(env, groupId, auth.accountId);
    } catch (e) {
      console.error("group leave: D1 write failed", String(e));
      return json({ error: "d1_error" }, 500);
    }
    return new Response(null, { status: 204 });
  }

  if (sub === "/kick") {
    const r = await call("/kick", { caller, targetMemberId: kickTarget });
    if (!r.ok) return fromDo(r);
    const { removed } = await r.json() as { removed: { kind: string; accountId?: string } | null };
    if (removed?.kind === "account" && removed.accountId) {
      try {
        await reconcileAccountIndex(env, groupId, removed.accountId);
      } catch (e) {
        console.error("group kick: D1 delete failed", String(e));
        return json({ error: "d1_error" }, 500);
      }
    }
    return new Response(null, { status: 204 });
  }

  if (sub === "/close") {
    const r = await call("/close", { caller });
    if (!r.ok) return fromDo(r);
    return new Response(null, { status: 204 });
  }

  // POST /invite/reset (owner only)
  const r = await call("/invite/reset", { caller });
  if (!r.ok) return fromDo(r);
  const { inviteCode, previousCode } = await r.json() as { inviteCode: string; previousCode: string };
  try {
    await db.prepare("DELETE FROM group_invites WHERE invite_code = ?1").bind(previousCode).run();
  } catch (e) {
    console.error("group invite reset: D1 delete failed", String(e));
    return json({ error: "d1_error" }, 500);
  }
  const bound = await bindGroupInviteCode(env, groupId, inviteCode, () => regenerateInvite(env, groupId, caller));
  if (bound instanceof Response) return bound;
  return json({ inviteCode: bound.code });
}
