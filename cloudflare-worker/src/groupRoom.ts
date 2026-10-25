// One Durable Object per group chat room, named by the client-generated
// groupId (ULID). Key/value storage (same API as DiaryRoom — no SQL):
//
//   meta                          → GroupMeta  (members, epoch, seq, invite …)
//   metacipher                    → string     (encrypted name/avatar blob, up
//                                               to 400 KB — kept out of `meta`
//                                               so every post doesn't rewrite
//                                               it; Ruling 15)
//   ev:<seq padded 12>            → GroupEvent
//   eid:<eventId>                 → seq        (idempotency: POST /events resend)
//   key:<epoch padded 10>:<memberId> → WrapRecord (room key wrapped to a member)
//   ban:<sha256hex>               → 1          (kicked identity; Ruling 13)
//   tkt:<sha256hex(ticket)>       → { memberId, exp }  (single-use WS ticket)
//   push:acct:<accountId>         → ms of the last msg push to that account
//   push:dev:<sha256hex(deviceId)> → same, for an anonymous member's device
//                                    (throttle keys follow the recipient
//                                    IDENTITY, so a Ruling-12 device move
//                                    doesn't reset them; dropped on leave/kick)
//
// D1 (group_members / group_invites) is only an index — the live membership
// set, invite code and key epochs live here. An anonymous member's deviceId
// exists ONLY in this DO's `meta` and never leaves it in any response; an
// account member has no deviceId here at all (Ruling 14).
//
// PUSH (Ruling 14): the DO only names recipients, the route sends. A 201
// /events/msg returns `recipients` — every member except the author that has
// no live socket (for an account member: none of its sockets is live) and
// wasn't pushed in the last 60 s — as {kind:"account", accountId} (the route
// fans out to all of the account's devices from D1/KV at send time) or
// {kind:"device", deviceId} (anonymous: its one stored device). A replay
// (200) always answers `recipients: []`. /request-key names the keyed
// account members other than the caller, unthrottled (the route caps it).
// No device list or push token is ever stored here.
//
// `caller` (from the route) must carry EVERY identity it authenticated:
// accountId whenever the device is signed in — also when it acts as an
// anonymous member — because /join checks the ban list against all of them
// (a kicked account must not rejoin anonymously from its own device).
//
// Every endpoint except /init answers 404 without touching storage when there
// is no `meta`, so a stray id can never materialise a room.
//
// Concurrency rule for every handler: read and validate the request body
// FIRST, then getMeta(), and between getMeta() and the final put await
// nothing but storage operations. Awaiting the body (or any other non-storage
// I/O) opens the DO's input gate, so another request could run and commit
// in between — a handler holding an earlier `meta` snapshot would then
// overwrite it (lost joins, seq going backwards, the 50-member cap broken).
//
// Retention: at most the newest 5,000 events (trimmed on every append) and
// nothing older than 90 days (trimmed by the alarm). `firstSeq` is the oldest
// seq still stored; a client whose `since` is below `firstSeq - 1` has a gap.
//
// WEBSOCKET (downstream only — posts go over HTTP, Ruling 1). Sockets are
// accepted with the hibernation API, tagged with the memberId so a removed or
// replaced member's sockets can be found and closed. Frames sent to clients
// are only `{"t":"ev","e":<GroupEvent>}`; frames from clients are never
// parsed or logged, they only refresh the socket's last-heard time.
//
// CLIENT CONTRACT (binding for G1b):
//   - Get a ticket (POST /v3/groups/:id/ws-ticket, 60 s, single use), then
//     GET /v3/groups/:id/ws?ticket=… with Upgrade: websocket.
//   - Send the TEXT frame exactly "ping" every 30 s (auto-answered "pong",
//     works while the DO hibernates). Protocol-level pings don't count; a
//     socket silent for > 90 s is treated as not connected.
//   - A socket lives at most 2 h. Close codes:
//       4000 replaced — this member opened a third socket; the oldest goes.
//       4001 expired  — 2 h hard cap reached: fetch a new ticket, reconnect,
//                       catch up with GET events since your last seq.
//       4003 removed  — you are no longer a member (left / kicked / taken
//                       over by your own newer device): stop reconnecting.
import { generateAccountId } from "./account";
import { decodedByteLength, isValidEventId, isValidGroupId, isValidMemberId, sha256Hex } from "./groupSig";
import type { PushPayload } from "./push";

export type GroupMemberKind = "account" | "anon";
export type JoinPolicy = "accountOnly" | "anonymousAllowed";
// account 成員：有 accountId、沒有 deviceId；anon 成員：有 deviceId、沒有 accountId（Ruling 14）
// `devHash` (anon only) = sha256hex(deviceId), the push-throttle key; never sent to clients.
export interface GroupMember { memberId: string; kind: GroupMemberKind; accountId?: string; deviceId?: string; devHash?: string; joinedAt: number; joinedEpoch: number; pubKey: string; pubKeySig?: string }
export type PushRecipient = { kind: "account"; accountId: string } | { kind: "device"; deviceId: string };
export interface GroupMeta { groupId: string; ownerMemberId: string | null; members: GroupMember[]; joinPolicy: JoinPolicy; discoverability: "private"; state: "open" | "closed"; epoch: number; seq: number; firstSeq: number; inviteCode: string; metaVersion: number; rotationDue: boolean; createdAt: number }
export type GroupEventType = "msg" | "join" | "leave" | "kick" | "meta";
// `meta` events carry the metaVersion they produced; a rotation's also has `rotated: true`
// (so /rotate and /meta replays can tell their own events apart).
export interface GroupEvent { seq: number; eventId: string; type: GroupEventType; authorMemberId: string; epoch: number; payloadCipher?: string; targetMemberId?: string; ownerMemberId?: string; metaVersion?: number; rotated?: true; createdAt: number }
export interface WrapRecord { wrapped: string; wrappedBy: string; sig: string; createdAt: number }
export interface Caller { memberId: string; accountId: string | null; deviceId: string; lane: "bearer" | "key" }
export interface PublicMember { memberId: string; kind: GroupMemberKind; accountId?: string; joinedAt: number; pubKey: string; pubKeySig?: string; hasKey: boolean }
export const GROUP_LIMITS = { maxMembers: 50, maxEvents: 5000, retentionMs: 90 * 86_400_000, maxPayloadBytes: 8 * 1024, maxMetaBytes: 400 * 1024, wrappedBytes: 92, sigBytes: 64, pubKeyBytes: 32, ticketTtlMs: 60_000, socketsPerMember: 2, staleMs: 90_000, hardCapMs: 2 * 3600_000, pushThrottleMs: 60_000, eventsDefaultLimit: 100, eventsMaxLimit: 500, msgsPerMinutePerMember: 30 } as const;

/**
 * Push payloads the route sends for this room (Task 7). Fixed text, no
 * group name, no sender: the alert is the localized "有新訊息" only.
 */
export const GROUP_PUSH = {
  message: (groupId: string): PushPayload => ({ alert: { "loc-key": "GROUP_MESSAGE" }, data: { type: "groupMessage", groupId } }),
  keyRequest: (groupId: string): PushPayload => ({ silent: true, data: { type: "groupKeyRequest", groupId } }),
};

const DAY_MS = 86_400_000;
const JOIN_POLICIES = new Set<string>(["accountOnly", "anonymousAllowed"]);

const padSeq = (n: number): string => String(n).padStart(12, "0");
const evKey = (seq: number): string => `ev:${padSeq(seq)}`;
const keyKey = (epoch: number, memberId: string): string => `key:${String(epoch).padStart(10, "0")}:${memberId}`;
/** Where the memberId starts in a `key:` storage key. */
const KEY_MEMBER_AT = "key:".length + 10 + 1;
/** The string whose sha256 is a member's `ban:` key (Ruling 13). */
const identityOf = (m: { kind: GroupMemberKind; accountId?: string; deviceId?: string }): string =>
  m.kind === "account" ? `acct:${m.accountId}` : `dev:${m.deviceId}`;
/** The push-throttle storage key of a member's identity (null: an anon member stored without devHash). */
const pushKeyOf = (m: GroupMember): string | null =>
  m.kind === "account" ? `push:acct:${m.accountId}` : m.devHash ? `push:dev:${m.devHash}` : null;
/** Who to push for a member: the account (all its devices) or the one anonymous device. */
const recipientOf = (m: GroupMember): PushRecipient =>
  m.kind === "account" ? { kind: "account", accountId: m.accountId! } : { kind: "device", deviceId: m.deviceId! };
/** What leave / kick tell the route about who went (never a deviceId). */
const removedView = (m: GroupMember): { kind: GroupMemberKind; accountId?: string } =>
  m.kind === "account" ? { kind: "account", accountId: m.accountId } : { kind: "anon" };

class BadRequest extends Error {}

const MAX_ACCOUNT_ID_LEN = 64;
const MAX_DEVICE_ID_LEN = 128;
const MAX_INVITE_CODE_LEN = 64;

const isBoundedString = (v: unknown, max: number): v is string => typeof v === "string" && v.length > 0 && v.length <= max;
/** True when `v` is strict base64 decoding to exactly `n` bytes. */
const isB64Bytes = (v: unknown, n: number): v is string => typeof v === "string" && decodedByteLength(v) === n;

function parseCaller(v: unknown): Caller {
  const c = v as Partial<Caller> | null;
  if (!c || typeof c !== "object") throw new BadRequest();
  if (!isValidMemberId(c.memberId) || !isBoundedString(c.deviceId, MAX_DEVICE_ID_LEN)) throw new BadRequest();
  if (c.accountId !== null && !isBoundedString(c.accountId, MAX_ACCOUNT_ID_LEN)) throw new BadRequest();
  if (c.lane !== "bearer" && c.lane !== "key") throw new BadRequest();
  return { memberId: c.memberId, accountId: c.accountId, deviceId: c.deviceId, lane: c.lane };
}

/**
 * Builds a member from an untrusted join body, copying only the fields its
 * kind allows. An account member carrying a deviceId is rejected outright
 * (this DO never stores an account member's device — Ruling 14).
 * `joinedEpoch` is filled in once the room's meta has been read.
 */
function parseJoinMember(v: unknown, now: number): GroupMember {
  const m = v as Record<string, unknown> | null;
  if (!m || typeof m !== "object") throw new BadRequest();
  if (!isValidMemberId(m.memberId) || !isB64Bytes(m.pubKey, GROUP_LIMITS.pubKeyBytes)) throw new BadRequest();
  if (m.kind === "account") {
    if (!isBoundedString(m.accountId, MAX_ACCOUNT_ID_LEN) || m.deviceId !== undefined) throw new BadRequest();
    if (!isB64Bytes(m.pubKeySig, GROUP_LIMITS.sigBytes)) throw new BadRequest();
    return { memberId: m.memberId, kind: "account", accountId: m.accountId, joinedAt: now, joinedEpoch: 0, pubKey: m.pubKey, pubKeySig: m.pubKeySig };
  }
  if (m.kind === "anon") {
    if (!isBoundedString(m.deviceId, MAX_DEVICE_ID_LEN) || m.accountId !== undefined) throw new BadRequest();
    return { memberId: m.memberId, kind: "anon", deviceId: m.deviceId, joinedAt: now, joinedEpoch: 0, pubKey: m.pubKey };
  }
  throw new BadRequest();
}

interface InitRequest {
  groupId: string;
  owner: { memberId: string; accountId: string; pubKey: string; pubKeySig: string };
  ownerWrap: { wrapped: string; sig: string };
  metaCipher: string;
  joinPolicy: JoinPolicy;
  inviteCode?: string;
}

/** Validates an /init body; a 413 for an oversized metaCipher, else throws BadRequest. */
function parseInit(b: Record<string, unknown>): InitRequest | "too_large" {
  const owner = b.owner as Record<string, unknown> | null;
  const wrap = b.ownerWrap as Record<string, unknown> | null;
  if (!owner || typeof owner !== "object" || !wrap || typeof wrap !== "object") throw new BadRequest();
  if (!isValidGroupId(b.groupId) || !isValidMemberId(owner.memberId) || !isBoundedString(owner.accountId, MAX_ACCOUNT_ID_LEN)) throw new BadRequest();
  if (!isB64Bytes(owner.pubKey, GROUP_LIMITS.pubKeyBytes) || !isB64Bytes(owner.pubKeySig, GROUP_LIMITS.sigBytes)) throw new BadRequest();
  if (!isB64Bytes(wrap.wrapped, GROUP_LIMITS.wrappedBytes) || !isB64Bytes(wrap.sig, GROUP_LIMITS.sigBytes)) throw new BadRequest();
  if (typeof b.joinPolicy !== "string" || !JOIN_POLICIES.has(b.joinPolicy)) throw new BadRequest();
  if (b.inviteCode !== undefined && !isBoundedString(b.inviteCode, MAX_INVITE_CODE_LEN)) throw new BadRequest();
  if (typeof b.metaCipher !== "string" || b.metaCipher.length === 0) throw new BadRequest();
  const metaLen = decodedByteLength(b.metaCipher);
  if (metaLen === null) throw new BadRequest();
  if (metaLen > GROUP_LIMITS.maxMetaBytes) return "too_large";
  return {
    groupId: b.groupId,
    owner: { memberId: owner.memberId, accountId: owner.accountId, pubKey: owner.pubKey, pubKeySig: owner.pubKeySig },
    ownerWrap: { wrapped: wrap.wrapped, sig: wrap.sig },
    metaCipher: b.metaCipher,
    joinPolicy: b.joinPolicy as JoinPolicy,
    inviteCode: b.inviteCode as string | undefined,
  };
}

interface JoinRequest { member: GroupMember; inviteCode: unknown; dryRun: boolean; banKeys: string[] }

/** Same person? Account members by accountId, anonymous ones by deviceId. */
const sameIdentity = (a: GroupMember, b: GroupMember): boolean =>
  a.kind === b.kind && (a.kind === "account" ? a.accountId === b.accountId : a.deviceId === b.deviceId);

/** A member as any other member may see it: never the deviceId (nor its hash). */
const stripDevice = ({ deviceId: _d, devHash: _h, ...rest }: GroupMember): GroupMember => rest;

const KNOWN_PATHS = new Set([
  "/init", "/view", "/join", "/close", "/invite/reset", "/events/list", "/events/msg", "/ws-ticket",
  "/keys/mine", "/keys/put", "/rotate", "/meta", "/meta-cipher", "/leave", "/kick", "/request-key",
  "/account-member",
]);

const WS_OPEN = 1;
const ALARM_PRUNE_BATCH = 1000;
const ALARM_RETRY_MS = 60_000;
/** Storage get/put/delete take at most 128 keys per call. */
const STORAGE_BATCH = 128;
const TICKET_RE = /^[A-Za-z0-9_-]{43}$/;

/** Hibernation-safe per-socket bookkeeping. */
interface SocketAtt { memberId: string; connectedAt: number; last: number }
interface TicketRecord { memberId: string; exp: number }

function chunks<T>(xs: T[], n = STORAGE_BATCH): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < xs.length; i += n) out.push(xs.slice(i, i + n));
  return out;
}

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const isNonNegInt = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;

interface ListRequest { caller: Caller; since: number; limit: number }
function parseList(b: Record<string, unknown>): ListRequest {
  const caller = parseCaller(b.caller);
  if (b.since !== undefined && !isNonNegInt(b.since)) throw new BadRequest();
  if (b.limit !== undefined && (typeof b.limit !== "number" || !Number.isSafeInteger(b.limit))) throw new BadRequest();
  const limit = Math.min(Math.max((b.limit as number | undefined) ?? GROUP_LIMITS.eventsDefaultLimit, 1), GROUP_LIMITS.eventsMaxLimit);
  return { caller, since: (b.since as number | undefined) ?? 0, limit };
}

/**
 * A parsed /events/msg body. Format problems are recorded rather than thrown
 * so they can be reported in the documented order (membership first) once
 * meta has been read — the parsing itself still happens before getMeta.
 */
interface MsgRequest { caller: Caller; eventId: string; epoch: number; payloadCipher: string; eventIdOk: boolean; payload: "ok" | "bad" | "too_large" }
function parseMsg(b: Record<string, unknown>): MsgRequest {
  const caller = parseCaller(b.caller);
  const { eventId, eventIdOk } = parseEventId(b.eventId);
  if (!isNonNegInt(b.epoch)) throw new BadRequest();
  const len = typeof b.payloadCipher === "string" && b.payloadCipher.length > 0 ? decodedByteLength(b.payloadCipher) : null;
  const payload = len === null || len === 0 ? "bad" : len > GROUP_LIMITS.maxPayloadBytes ? "too_large" : "ok";
  return {
    caller, eventId, epoch: b.epoch, payloadCipher: payload === "ok" ? b.payloadCipher as string : "",
    eventIdOk, payload,
  };
}

type SizeStatus = "ok" | "bad" | "too_large";
/** A metaCipher's validity, measured before meta is read and reported after. */
function metaCipherStatus(v: unknown): SizeStatus {
  if (typeof v !== "string") throw new BadRequest();
  const len = v.length > 0 ? decodedByteLength(v) : null;
  return len === null || len === 0 ? "bad" : len > GROUP_LIMITS.maxMetaBytes ? "too_large" : "ok";
}

/** A client eventId: structurally wrong → 400 bad_request now; not a ULID → bad_event_id later. */
function parseEventId(v: unknown): { eventId: string; eventIdOk: boolean } {
  if (typeof v !== "string" || v.length > 64) throw new BadRequest();
  return { eventId: v, eventIdOk: isValidEventId(v) };
}

interface WrapIn { memberId: string; wrapped: string; sig: string }
/**
 * A wraps array. Structure (array of {memberId, wrapped, sig} strings, no
 * repeated memberId, at most maxMembers) is checked now; byte lengths
 * (92 / 64) are recorded in `ok` and reported as bad_wrap after membership.
 */
function parseWraps(v: unknown): { wraps: WrapIn[]; ok: boolean } {
  if (!Array.isArray(v) || v.length > GROUP_LIMITS.maxMembers) throw new BadRequest();
  const seen = new Set<string>();
  const wraps: WrapIn[] = [];
  let ok = true;
  for (const w of v) {
    if (!w || typeof w !== "object") throw new BadRequest();
    const { memberId, wrapped, sig } = w as Record<string, unknown>;
    if (!isValidMemberId(memberId) || seen.has(memberId) || typeof wrapped !== "string" || typeof sig !== "string") throw new BadRequest();
    seen.add(memberId);
    if (!isB64Bytes(wrapped, GROUP_LIMITS.wrappedBytes) || !isB64Bytes(sig, GROUP_LIMITS.sigBytes)) ok = false;
    wraps.push({ memberId, wrapped, sig });
  }
  return { wraps, ok };
}

interface PutKeysRequest { caller: Caller; epoch: number; wraps: WrapIn[]; wrapsOk: boolean }
function parsePutKeys(b: Record<string, unknown>): PutKeysRequest {
  const caller = parseCaller(b.caller);
  if (!isNonNegInt(b.epoch)) throw new BadRequest();
  const { wraps, ok } = parseWraps(b.wraps);
  return { caller, epoch: b.epoch, wraps, wrapsOk: ok };
}

interface RotateRequest extends PutKeysRequest { eventId: string; eventIdOk: boolean; metaCipher: string; metaStatus: SizeStatus }
function parseRotate(b: Record<string, unknown>): RotateRequest {
  return { ...parsePutKeys(b), ...parseEventId(b.eventId), metaCipher: b.metaCipher as string, metaStatus: metaCipherStatus(b.metaCipher) };
}

interface MetaRequest { caller: Caller; eventId: string; eventIdOk: boolean; metaCipher: string; metaStatus: SizeStatus; joinPolicy?: JoinPolicy; removeAnonymous: boolean }
function parseMetaUpdate(b: Record<string, unknown>): MetaRequest {
  const caller = parseCaller(b.caller);
  const { eventId, eventIdOk } = parseEventId(b.eventId);
  const metaStatus = metaCipherStatus(b.metaCipher);
  if (b.joinPolicy !== undefined && (typeof b.joinPolicy !== "string" || !JOIN_POLICIES.has(b.joinPolicy))) throw new BadRequest();
  if (b.removeAnonymous !== undefined && typeof b.removeAnonymous !== "boolean") throw new BadRequest();
  // Dropping anonymous members only makes sense together with closing the door on them.
  if (b.removeAnonymous === true && b.joinPolicy !== "accountOnly") throw new BadRequest();
  return {
    caller, eventId, eventIdOk, metaCipher: b.metaCipher as string, metaStatus,
    joinPolicy: b.joinPolicy as JoinPolicy | undefined, removeAnonymous: b.removeAnonymous === true,
  };
}

interface KickRequest { caller: Caller; targetMemberId: string }
function parseKick(b: Record<string, unknown>): KickRequest {
  const caller = parseCaller(b.caller);
  if (!isValidMemberId(b.targetMemberId)) throw new BadRequest();
  return { caller, targetMemberId: b.targetMemberId };
}

type NewEvent = Omit<GroupEvent, "seq">;
export type RemoveReason = "leave" | "kick" | "replace";
interface RemoveOpts {
  /** The kicker (kick only). */
  by?: string;
  /** Events committed before / after the removal events, in the same write. */
  before?: NewEvent[];
  after?: NewEvent[];
  extraWrites?: Record<string, unknown>;
}

export class GroupRoom {
  ctx: DurableObjectState;
  /** Clock seam for tests. */
  now: () => number = () => Date.now();

  /**
   * Per-member post timestamps for the 30-a-minute limit. In memory only:
   * it resets when the DO is evicted, which is an acceptable leak for a
   * flood guard (the Worker's IP bucket still applies).
   */
  private postTimes = new Map<string, number[]>();

  constructor(ctx: DurableObjectState, _env: unknown) {
    this.ctx = ctx;
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  private json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
  }

  private getMeta(): Promise<GroupMeta | undefined> {
    return this.ctx.storage.get<GroupMeta>("meta");
  }

  /**
   * Resolves `caller` to a member of this room, or an error response. The
   * Bearer-lane check for anonymous members runs here — before any handler
   * gets to write — because the key lane's deviceId is self-reported and
   * would let anyone holding the Mac key impersonate an anonymous member
   * (Ruling 5).
   */
  authorize(meta: GroupMeta, caller: Caller): GroupMember | Response {
    const member = this.resolve(meta, caller);
    if (member === "bearer_required") return this.json({ error: "bearer_required" }, 401);
    return member ?? this.json({ error: "not_member" }, 403);
  }

  /** authorize() without the responses: the member, null, or the lane refusal. */
  private resolve(meta: GroupMeta, caller: Caller): GroupMember | null | "bearer_required" {
    const member = meta.members.find((m) => m.memberId === caller.memberId);
    if (!member) return null;
    if (member.kind === "anon") {
      if (caller.lane === "key") return "bearer_required";
      if (member.deviceId !== caller.deviceId) return null;
    } else if (member.accountId !== caller.accountId) {
      return null;
    }
    return member;
  }

  /**
   * Assigns the next seq(s) to `events` and commits them together with
   * `meta`, `extraWrites` and `extraDeletes` atomically. Client-posted
   * events also get their `eid:` idempotency entry; "srv:" ids are reserved
   * for server-written events and can never be replayed by a client.
   * Keeps at most GROUP_LIMITS.maxEvents: the oldest overflow (with its
   * `eid:`) is deleted in the same commit and `firstSeq` moves up. Then
   * fans the new events out to connected sockets.
   */
  async appendEvent(
    meta: GroupMeta,
    events: Omit<GroupEvent, "seq"> | Omit<GroupEvent, "seq">[],
    extraWrites: Record<string, unknown> = {},
    extraDeletes: string[] = [],
  ): Promise<GroupEvent[]> {
    const out: GroupEvent[] = [];
    const writes: Record<string, unknown> = { ...extraWrites };
    for (const ev of Array.isArray(events) ? events : [events]) {
      meta.seq += 1;
      const full = { ...ev, seq: meta.seq } as GroupEvent;
      writes[evKey(full.seq)] = full;
      if (!full.eventId.startsWith("srv:")) writes[`eid:${full.eventId}`] = full.seq;
      out.push(full);
    }
    const deletes = [...extraDeletes];
    const overflow = meta.seq - meta.firstSeq + 1 - GROUP_LIMITS.maxEvents;
    if (overflow > 0) {
      const oldKeys: string[] = [];
      for (let s = meta.firstSeq; s < meta.firstSeq + overflow; s++) if (!(evKey(s) in writes)) oldKeys.push(evKey(s));
      // A storage read (the input gate stays shut); every write below is
      // issued after it with no await in between, so they commit as one.
      for (const part of chunks(oldKeys)) {
        for (const [k, ev] of await this.ctx.storage.get<GroupEvent>(part)) {
          if (!ev.eventId.startsWith("srv:")) deletes.push(`eid:${ev.eventId}`);
          deletes.push(k);
        }
      }
      meta.firstSeq += overflow;
    }
    writes.meta = meta;
    const ops: Promise<unknown>[] = chunks(deletes).map((d) => this.ctx.storage.delete(d));
    for (const part of chunks(Object.entries(writes))) ops.push(this.ctx.storage.put(Object.fromEntries(part)));
    await Promise.all(ops);
    for (const ev of out) this.broadcast(ev);
    return out;
  }

  /**
   * Storage keys that die with these members: every wrap (all epochs) and
   * ticket, plus — unless it is a Ruling-12 replacement, where the same
   * identity stays — the identity's push-throttle stamp.
   */
  private async memberKeys(removed: GroupMember[], reason: RemoveReason): Promise<string[]> {
    const ids = new Set(removed.map((m) => m.memberId));
    const out: string[] = [];
    for (const k of (await this.ctx.storage.list({ prefix: "key:" })).keys()) if (ids.has(k.slice(KEY_MEMBER_AT))) out.push(k);
    for (const [k, t] of await this.ctx.storage.list<TicketRecord>({ prefix: "tkt:" })) if (ids.has(t.memberId)) out.push(k);
    if (reason !== "replace") {
      for (const m of removed) {
        const k = pushKeyOf(m);
        if (k) out.push(k);
      }
    }
    return out;
  }

  /**
   * Idempotent replay of a client eventId: the stored event when it is this
   * member's own event of `type` (and, if given, passes `match`), a 409
   * event_id_taken when the id belongs to someone else or another kind of
   * event, null when it's unused. `match` separates /rotate's `meta` events
   * (rotated: true) from /meta's, which share the type.
   */
  private async replayOf(eventId: string, me: GroupMember, type: GroupEventType, match?: (e: GroupEvent) => boolean): Promise<GroupEvent | Response | null> {
    const seq = await this.ctx.storage.get<number>(`eid:${eventId}`);
    if (seq === undefined) return null;
    const event = await this.ctx.storage.get<GroupEvent>(evKey(seq));
    if (!event || event.authorMemberId !== me.memberId || event.type !== type || (match && !match(event))) return this.json({ error: "event_id_taken" }, 409);
    return event;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    if (request.method === "GET" && path === "/ws") return await this.upgrade(request, url);
    if (request.method !== "POST" || !KNOWN_PATHS.has(path)) return this.json({ error: "not_found" }, 404);
    try {
      // 1. Body first (this await opens the input gate — see file header).
      const body = await request.json().catch(() => { throw new BadRequest(); }) as Record<string, unknown>;
      if (!body || typeof body !== "object") throw new BadRequest();
      // 2. Validate and do any non-storage async work (hashing) up front.
      if (path === "/init") {
        const init = parseInit(body);
        if (init === "too_large") return this.json({ error: "too_large" }, 413);
        return await this.init(init);
      }
      if (path === "/join") {
        const req = await this.parseJoin(body);
        if (req instanceof Response) return req;
        // 3. Only now read meta; nothing below awaits non-storage I/O.
        const meta = await this.getMeta();
        if (!meta) return this.json({ error: "not_found" }, 404);
        return await this.join(meta, req);
      }
      if (path === "/events/list") {
        const req = parseList(body);
        const meta = await this.getMeta();
        if (!meta) return this.json({ error: "not_found" }, 404);
        return await this.listEvents(meta, req);
      }
      if (path === "/events/msg") {
        const req = parseMsg(body);
        const meta = await this.getMeta();
        if (!meta) return this.json({ error: "not_found" }, 404);
        return await this.postMsg(meta, req);
      }
      if (path === "/ws-ticket") {
        const caller = parseCaller(body.caller);
        // Ticket and its hash are made before meta (crypto is non-storage I/O).
        const ticket = b64url(crypto.getRandomValues(new Uint8Array(32)));
        const hash = await sha256Hex(ticket);
        const meta = await this.getMeta();
        if (!meta) return this.json({ error: "not_found" }, 404);
        return await this.issueTicket(meta, caller, ticket, hash);
      }
      if (path === "/keys/put") {
        const req = parsePutKeys(body);
        const meta = await this.getMeta();
        if (!meta) return this.json({ error: "not_found" }, 404);
        return await this.putKeys(meta, req);
      }
      if (path === "/rotate") {
        const req = parseRotate(body);
        const meta = await this.getMeta();
        if (!meta) return this.json({ error: "not_found" }, 404);
        return await this.rotate(meta, req);
      }
      if (path === "/meta") {
        const req = parseMetaUpdate(body);
        const meta = await this.getMeta();
        if (!meta) return this.json({ error: "not_found" }, 404);
        return await this.updateMeta(meta, req);
      }
      // kick reads meta itself: it has a hash to compute once it knows the target.
      if (path === "/kick") return await this.kick(parseKick(body));
      if (path === "/account-member") {
        // Read-only, for the route's D1 index repair: does this account hold
        // a seat? A wiped room (no meta) seats nobody. Never writes.
        if (!isBoundedString(body.accountId, MAX_ACCOUNT_ID_LEN)) throw new BadRequest();
        const meta = await this.getMeta();
        return this.json({ member: !!meta && meta.members.some((m) => m.kind === "account" && m.accountId === body.accountId) });
      }
      const caller = parseCaller(body.caller);
      const meta = await this.getMeta();
      if (!meta) return this.json({ error: "not_found" }, 404);
      if (path === "/keys/mine") return await this.keysMine(meta, caller);
      if (path === "/meta-cipher") return await this.metaCipher(meta, caller);
      if (path === "/leave") return await this.leave(meta, caller);
      if (path === "/view") return await this.view(meta, caller);
      if (path === "/request-key") return await this.requestKey(meta, caller);
      if (path === "/close") return await this.close(meta, caller);
      return await this.resetInvite(meta, caller);
    } catch (e) {
      if (e instanceof BadRequest) return this.json({ error: "bad_request" }, 400);
      throw e;
    }
  }

  // ---- create / idempotent re-create -----------------------------------
  private async init(body: InitRequest): Promise<Response> {
    const { owner, ownerWrap: wrap } = body;
    const existing = await this.getMeta();
    if (existing) {
      const existingOwner = existing.members.find((m) => m.memberId === existing.ownerMemberId);
      if (existingOwner && existingOwner.accountId === owner.accountId) {
        return this.json({ ...existing, members: existing.members.map(stripDevice) }, 200);
      }
      return this.json({ error: "group_exists" }, 409);
    }

    const now = this.now();
    const meta: GroupMeta = {
      groupId: body.groupId,
      ownerMemberId: owner.memberId,
      members: [{ memberId: owner.memberId, kind: "account", accountId: owner.accountId, joinedAt: now, joinedEpoch: 1, pubKey: owner.pubKey, pubKeySig: owner.pubKeySig }],
      joinPolicy: body.joinPolicy,
      discoverability: "private",
      state: "open",
      epoch: 1,
      seq: 0,
      firstSeq: 1,
      inviteCode: body.inviteCode ?? generateAccountId(),
      metaVersion: 1,
      rotationDue: false,
      createdAt: now,
    };
    const ownerWrap: WrapRecord = { wrapped: wrap.wrapped, wrappedBy: owner.memberId, sig: wrap.sig, createdAt: now };
    // Both issued before either is awaited, so they commit together.
    const put = this.ctx.storage.put({ meta, metacipher: body.metaCipher, [keyKey(1, owner.memberId)]: ownerWrap });
    const alarm = this.ctx.storage.setAlarm(now + DAY_MS);
    await Promise.all([put, alarm]);
    return this.json(meta, 201);
  }

  // ---- view ----------------------------------------------------------------
  private async view(meta: GroupMeta, caller: Caller): Promise<Response> {
    const me = this.authorize(meta, caller);
    if (me instanceof Response) return me;
    const held = await this.ctx.storage.get(meta.members.map((m) => keyKey(meta.epoch, m.memberId)));
    const members: PublicMember[] = meta.members.map((m) => {
      const p: PublicMember = { memberId: m.memberId, kind: m.kind, joinedAt: m.joinedAt, pubKey: m.pubKey, hasKey: held.has(keyKey(meta.epoch, m.memberId)) };
      if (m.accountId !== undefined) p.accountId = m.accountId;
      if (m.pubKeySig !== undefined) p.pubKeySig = m.pubKeySig;
      return p;
    });
    const out: Record<string, unknown> = {
      groupId: meta.groupId, ownerMemberId: meta.ownerMemberId, members, joinPolicy: meta.joinPolicy,
      discoverability: meta.discoverability, state: meta.state, epoch: meta.epoch, seq: meta.seq,
      firstSeq: meta.firstSeq, metaVersion: meta.metaVersion, rotationDue: meta.rotationDue,
    };
    if (me.memberId === meta.ownerMemberId) out.inviteCode = meta.inviteCode;
    return this.json(out);
  }

  // ---- join ------------------------------------------------------------------
  /**
   * Validates a join body and binds the joining identity to the
   * authenticated caller: the DO never takes the member's accountId /
   * deviceId on the body's word. An account member must be the caller's own
   * accountId (on either lane — the route only puts an accountId in `caller`
   * that it authenticated, including the Mac key lane's device→account
   * lookup); an anonymous member must be the caller's own deviceId AND come
   * over the Bearer lane, the same Ruling-5 rule as authorize(). Runs before
   * getMeta, so it is also where the ban hash is computed.
   */
  private async parseJoin(body: Record<string, unknown>): Promise<JoinRequest | Response> {
    const caller = parseCaller(body.caller);
    const member = parseJoinMember(body.member, this.now());
    if (caller.memberId !== member.memberId) throw new BadRequest();
    if (member.kind === "anon") {
      if (caller.lane === "key") return this.json({ error: "bearer_required" }, 401);
      if (caller.deviceId !== member.deviceId) return this.json({ error: "identity_mismatch" }, 403);
    } else if (caller.accountId !== member.accountId) {
      return this.json({ error: "identity_mismatch" }, 403);
    }
    // Ban check covers every identity the caller authenticated as, not just
    // the one it joins under: a kicked account must not slip back in as an
    // anonymous member from its own device, nor a kicked anonymous device
    // by signing in with an account on it. (The key lane's deviceId is
    // self-reported, so it is neither trusted for nor held against anyone.)
    // Binding above makes the member's own identity one of these.
    const idents: string[] = [];
    if (caller.accountId !== null) idents.push(identityOf({ kind: "account", accountId: caller.accountId }));
    if (caller.lane === "bearer") idents.push(identityOf({ kind: "anon", deviceId: caller.deviceId }));
    const banKeys = await Promise.all(idents.map(async (i) => `ban:${await sha256Hex(i)}`));
    // The anonymous member's push-throttle key, hashed now (not after getMeta).
    if (member.kind === "anon") member.devHash = await sha256Hex(member.deviceId!);
    return { member, inviteCode: body.inviteCode, dryRun: body.dryRun === true, banKeys };
  }

  private async join(meta: GroupMeta, req: JoinRequest): Promise<Response> {
    const { member, dryRun } = req;
    member.joinedEpoch = meta.epoch;
    const now = member.joinedAt;

    const prior = meta.members.find((m) => sameIdentity(m, member));
    // Idempotent short-circuit beats every check below: an existing member
    // replaying a stale invite link needs no fresh authorization.
    if (prior && prior.memberId === member.memberId) return this.json({ added: false }, 200);
    if ((await this.ctx.storage.get(req.banKeys)).size > 0) return this.json({ error: "banned" }, 403);
    // Authoritative code check (D1's group_invites only maps code → groupId).
    if (meta.inviteCode !== req.inviteCode) return this.json({ error: "bad_code" }, 403);
    if (meta.state === "closed") return this.json({ error: "group_closed" }, 403);
    if (member.kind === "anon" && meta.joinPolicy === "accountOnly") return this.json({ error: "account_required" }, 403);
    // A replacement doesn't grow the room, so the old seat doesn't count.
    if (meta.members.length - (prior ? 1 : 0) >= GROUP_LIMITS.maxMembers) return this.json({ error: "group_full_members" }, 409);
    if (meta.members.some((m) => m.memberId === member.memberId)) return this.json({ error: "member_id_taken" }, 409);
    if (dryRun) return this.json({ added: true, replaced: !!prior }, 201);

    if (prior) {
      // Ruling 12: same identity on a new device takes over atomically —
      // old memberId out (with its wraps), new one in, ownership carried
      // over. No rotationDue: it's the same person, who already had those
      // keys. "srv:" ids embed the seq the event will get.
      // Ownership moves first, so removeMember sees no owner leaving.
      const wasOwner = meta.ownerMemberId === prior.memberId;
      meta.members.push(member);
      if (wasOwner) meta.ownerMemberId = member.memberId;
      // removeMember writes leave(old) at seq+1, so the join is seq+2.
      const joinEv: NewEvent = { eventId: `srv:join:${member.memberId}:${meta.seq + 2}`, type: "join", authorMemberId: member.memberId, epoch: meta.epoch, createdAt: now };
      if (wasOwner) joinEv.ownerMemberId = member.memberId;
      // The old memberId is gone for good, so its sockets get 4003 "removed".
      await this.removeMember(meta, prior.memberId, "replace", { after: [joinEv] });
      return this.json({ added: true, replaced: true }, 201);
    }

    meta.members.push(member);
    await this.appendEvent(meta, { eventId: `srv:join:${member.memberId}:${meta.seq + 1}`, type: "join", authorMemberId: member.memberId, epoch: meta.epoch, createdAt: now });
    return this.json({ added: true, replaced: false }, 201);
  }

  // ---- close (owner-only) --------------------------------------------------
  private async close(meta: GroupMeta, caller: Caller): Promise<Response> {
    const me = this.authorize(meta, caller);
    if (me instanceof Response) return me;
    if (me.memberId !== meta.ownerMemberId) return this.json({ error: "not_owner" }, 403);
    if (meta.state !== "closed") {
      meta.state = "closed";
      await this.ctx.storage.put("meta", meta);
    }
    return this.json({ state: meta.state });
  }

  // ---- invite/reset (owner-only) -------------------------------------------
  private async resetInvite(meta: GroupMeta, caller: Caller): Promise<Response> {
    const me = this.authorize(meta, caller);
    if (me instanceof Response) return me;
    if (me.memberId !== meta.ownerMemberId) return this.json({ error: "not_owner" }, 403);
    const previousCode = meta.inviteCode;
    meta.inviteCode = generateAccountId();
    await this.ctx.storage.put("meta", meta);
    return this.json({ inviteCode: meta.inviteCode, previousCode });
  }

  // ---- events ---------------------------------------------------------------
  private async listEvents(meta: GroupMeta, req: ListRequest): Promise<Response> {
    const me = this.authorize(meta, req.caller);
    if (me instanceof Response) return me;
    const from = Math.max(req.since, meta.firstSeq - 1);
    const results = await this.ctx.storage.list<GroupEvent>({ prefix: "ev:", startAfter: evKey(from), limit: req.limit + 1 });
    const all = [...results.values()];
    const page = all.slice(0, req.limit);
    const out: { events: GroupEvent[]; firstSeq: number; nextSince?: number } = { events: page, firstSeq: meta.firstSeq };
    if (all.length > req.limit && page.length) out.nextSince = page[page.length - 1].seq;
    return this.json(out);
  }

  private async postMsg(meta: GroupMeta, req: MsgRequest): Promise<Response> {
    const me = this.authorize(meta, req.caller);
    if (me instanceof Response) return me;
    // Exact-eventId replay: the original result, no re-validation, no
    // fan-out — even once the room has closed, so a retry after a lost
    // response still learns its post landed.
    if (req.eventIdOk) {
      const prior = await this.replayOf(req.eventId, me, "msg");
      if (prior instanceof Response) return prior;
      if (prior) return this.json({ seq: prior.seq, event: prior, recipients: [] }, 200);
    }
    if (meta.state !== "open") return this.json({ error: "group_closed" }, 403);
    if (!req.eventIdOk) return this.json({ error: "bad_event_id" }, 400);

    if (req.epoch !== meta.epoch) return this.json({ error: "stale_epoch", epoch: meta.epoch }, 409);
    if (await this.ctx.storage.get(keyKey(meta.epoch, me.memberId)) === undefined) return this.json({ error: "awaiting_key" }, 403);
    if (req.payload === "bad") return this.json({ error: "bad_payload" }, 400);
    if (req.payload === "too_large") return this.json({ error: "too_large" }, 413);

    // Rate check and the slot it takes happen together, synchronously, so a
    // parallel burst can't all pass before any is counted.
    const now = this.now();
    const recent = (this.postTimes.get(me.memberId) ?? []).filter((t) => now - t < 60_000);
    if (recent.length >= GROUP_LIMITS.msgsPerMinutePerMember) {
      this.postTimes.set(me.memberId, recent);
      return this.json({ error: "rate_limited" }, 429);
    }
    recent.push(now);
    this.postTimes.set(me.memberId, recent);

    const { recipients, stamps } = await this.msgRecipients(meta, me, now);
    const [event] = await this.appendEvent(meta, {
      eventId: req.eventId, type: "msg", authorMemberId: me.memberId, epoch: meta.epoch, payloadCipher: req.payloadCipher, createdAt: now,
    }, stamps);
    return this.json({ seq: event.seq, event, recipients }, 201);
  }

  /**
   * Who a new msg by `me` should push: every other member without a live
   * socket (isConnected covers all of a member's sockets) whose identity's
   * throttle stamp is absent or ≥ 60 s old. Returns the new stamps for the
   * caller to commit with the event — only a storage read happens here, so
   * parallel posts can't both pass the same stamp.
   */
  private async msgRecipients(meta: GroupMeta, me: GroupMember, now: number): Promise<{ recipients: PushRecipient[]; stamps: Record<string, number> }> {
    const offline = meta.members.filter((m) => m.memberId !== me.memberId && !this.isConnected(m.memberId));
    const keys = offline.map(pushKeyOf).filter((k): k is string => k !== null);
    const last = keys.length ? await this.ctx.storage.get<number>(keys) : new Map<string, number>();
    const recipients: PushRecipient[] = [];
    const stamps: Record<string, number> = {};
    for (const m of offline) {
      const k = pushKeyOf(m);
      if (k) {
        const t = last.get(k);
        if (t !== undefined && now - t < GROUP_LIMITS.pushThrottleMs) continue;
        stamps[k] = now;
      }
      recipients.push(recipientOf(m));
    }
    return { recipients, stamps };
  }

  /**
   * Who to ask for the current key: the account members (other than the
   * caller) holding a current-epoch wrap — only they may relay (Ruling 7).
   * Not throttled here; the route caps it at 6 an hour per member. No writes.
   */
  private async requestKey(meta: GroupMeta, caller: Caller): Promise<Response> {
    const me = this.authorize(meta, caller);
    if (me instanceof Response) return me;
    const others = meta.members.filter((m) => m.kind === "account" && m.memberId !== me.memberId);
    const held = others.length ? await this.ctx.storage.get(others.map((m) => keyKey(meta.epoch, m.memberId))) : new Map();
    const recipients = others.filter((m) => held.has(keyKey(meta.epoch, m.memberId))).map(recipientOf);
    return this.json({ recipients });
  }

  // ---- key wraps ----------------------------------------------------------------
  /** The caller's own wraps, every epoch still stored, oldest first. */
  private async keysMine(meta: GroupMeta, caller: Caller): Promise<Response> {
    const me = this.authorize(meta, caller);
    if (me instanceof Response) return me;
    const wraps: { epoch: number; wrapped: string; wrappedBy: string; sig: string }[] = [];
    // Keys sort by zero-padded epoch, so the list is already ascending.
    for (const [k, w] of await this.ctx.storage.list<WrapRecord>({ prefix: "key:" })) {
      if (k.slice(KEY_MEMBER_AT) === me.memberId) wraps.push({ epoch: Number(k.slice(4, KEY_MEMBER_AT - 1)), wrapped: w.wrapped, wrappedBy: w.wrappedBy, sig: w.sig });
    }
    return this.json({ wraps });
  }

  /**
   * Relays current-epoch wraps to members awaiting a key (Ruling 7): only a
   * keyed ACCOUNT member may relay (an anonymous wrap can't be signature-
   * checked), first write wins for members, the owner may overwrite. The
   * route verifies each wrap's signature before this runs; the DO only
   * checks sizes and membership.
   */
  private async putKeys(meta: GroupMeta, req: PutKeysRequest): Promise<Response> {
    const me = this.authorize(meta, req.caller);
    if (me instanceof Response) return me;
    if (me.kind !== "account") return this.json({ error: "account_required" }, 403);
    if (await this.ctx.storage.get(keyKey(meta.epoch, me.memberId)) === undefined) return this.json({ error: "not_keyed" }, 403);
    if (req.epoch !== meta.epoch) return this.json({ error: "stale_epoch", epoch: meta.epoch }, 409);
    const ids = new Set(meta.members.map((m) => m.memberId));
    if (req.wraps.some((w) => !ids.has(w.memberId))) return this.json({ error: "unknown_member" }, 400);
    if (!req.wrapsOk) return this.json({ error: "bad_wrap" }, 400);

    const isOwner = me.memberId === meta.ownerMemberId;
    const held = req.wraps.length ? await this.ctx.storage.get(req.wraps.map((w) => keyKey(meta.epoch, w.memberId))) : new Map();
    const now = this.now();
    const writes: Record<string, WrapRecord> = {};
    const written: string[] = [];
    const skipped: string[] = [];
    for (const w of req.wraps) {
      const k = keyKey(meta.epoch, w.memberId);
      if (held.has(k) && !isOwner) { skipped.push(w.memberId); continue; }
      writes[k] = { wrapped: w.wrapped, wrappedBy: me.memberId, sig: w.sig, createdAt: now };
      written.push(w.memberId);
    }
    if (written.length) await this.ctx.storage.put(writes);
    return this.json({ written, skipped });
  }

  /**
   * Atomic epoch rotation (Ruling 9): owner only, open rooms only, epoch
   * must be exactly current+1 and the wraps must cover exactly the current
   * members — anyone joining or leaving after the owner read the member
   * list makes this a 409 members_changed carrying the current memberIds,
   * so a newcomer is never left without the new key and a removed member
   * never gets it. Wraps, metacipher, meta and the `meta` event commit in
   * one write.
   */
  private async rotate(meta: GroupMeta, req: RotateRequest): Promise<Response> {
    const me = this.authorize(meta, req.caller);
    if (me instanceof Response) return me;
    if (req.eventIdOk) {
      const prior = await this.replayOf(req.eventId, me, "meta", (e) => e.rotated === true);
      if (prior instanceof Response) return prior;
      if (prior) return this.json({ seq: prior.seq, epoch: prior.epoch }, 200);
    }
    if (me.memberId !== meta.ownerMemberId) return this.json({ error: "not_owner" }, 403);
    if (meta.state !== "open") return this.json({ error: "group_closed" }, 403);
    if (!req.eventIdOk) return this.json({ error: "bad_event_id" }, 400);
    if (req.epoch !== meta.epoch + 1) return this.json({ error: "stale_epoch", epoch: meta.epoch }, 409);
    if (!req.wrapsOk) return this.json({ error: "bad_wrap" }, 400);
    if (req.metaStatus === "bad") return this.json({ error: "bad_request" }, 400);
    const current = meta.members.map((m) => m.memberId);
    const sent = new Set(req.wraps.map((w) => w.memberId));
    if (sent.size !== current.length || current.some((id) => !sent.has(id))) {
      return this.json({ error: "members_changed", memberIds: current }, 409);
    }
    if (req.metaStatus === "too_large") return this.json({ error: "too_large" }, 413);

    const now = this.now();
    const epoch = meta.epoch + 1;
    const writes: Record<string, unknown> = { metacipher: req.metaCipher };
    for (const w of req.wraps) writes[keyKey(epoch, w.memberId)] = { wrapped: w.wrapped, wrappedBy: me.memberId, sig: w.sig, createdAt: now } satisfies WrapRecord;
    meta.epoch = epoch;
    meta.metaVersion += 1;
    meta.rotationDue = false;
    const [ev] = await this.appendEvent(meta, { eventId: req.eventId, type: "meta", authorMemberId: me.memberId, epoch, metaVersion: meta.metaVersion, rotated: true, createdAt: now }, writes);
    return this.json({ seq: ev.seq, epoch }, 201);
  }

  // ---- metaCipher / settings (owner-only) ------------------------------------
  /**
   * Replaces the encrypted name/avatar blob and optionally the join policy.
   * With removeAnonymous (only alongside joinPolicy "accountOnly") every
   * anonymous member is removed in the same commit — one `kick` event each,
   * NOT banned — which sets rotationDue. The `meta` event carries no
   * payloadCipher; clients fetch /meta-cipher.
   */
  private async updateMeta(meta: GroupMeta, req: MetaRequest): Promise<Response> {
    const me = this.authorize(meta, req.caller);
    if (me instanceof Response) return me;
    if (req.eventIdOk) {
      const prior = await this.replayOf(req.eventId, me, "meta", (e) => e.rotated !== true);
      if (prior instanceof Response) return prior;
      // The metaVersion that write produced (stored on its event).
      if (prior) return this.json({ seq: prior.seq, metaVersion: prior.metaVersion ?? meta.metaVersion }, 200);
    }
    if (me.memberId !== meta.ownerMemberId) return this.json({ error: "not_owner" }, 403);
    if (meta.state !== "open") return this.json({ error: "group_closed" }, 403);
    if (!req.eventIdOk) return this.json({ error: "bad_event_id" }, 400);
    if (req.metaStatus === "bad") return this.json({ error: "bad_request" }, 400);
    if (req.metaStatus === "too_large") return this.json({ error: "too_large" }, 413);

    const seq = meta.seq + 1;
    meta.metaVersion += 1;
    if (req.joinPolicy) meta.joinPolicy = req.joinPolicy;
    const metaEv: NewEvent = { eventId: req.eventId, type: "meta", authorMemberId: me.memberId, epoch: meta.epoch, metaVersion: meta.metaVersion, createdAt: this.now() };
    const anonIds = req.removeAnonymous ? meta.members.filter((m) => m.kind === "anon").map((m) => m.memberId) : [];
    await this.removeMembers(meta, anonIds, "kick", { by: me.memberId, before: [metaEv], extraWrites: { metacipher: req.metaCipher } });
    return this.json({ seq, metaVersion: meta.metaVersion }, 201);
  }

  private async metaCipher(meta: GroupMeta, caller: Caller): Promise<Response> {
    const me = this.authorize(meta, caller);
    if (me instanceof Response) return me;
    return this.json({ metaCipher: await this.ctx.storage.get<string>("metacipher"), metaVersion: meta.metaVersion });
  }

  // ---- leave / kick -------------------------------------------------------------
  /** Leaving is idempotent: a non-member gets 200 with `removed: null`. */
  private async leave(meta: GroupMeta, caller: Caller): Promise<Response> {
    const me = this.resolve(meta, caller);
    if (me === "bearer_required") return this.json({ error: "bearer_required" }, 401);
    if (!me) return this.json({ remaining: meta.members.length, removed: null });
    await this.removeMember(meta, me.memberId, "leave");
    return this.json({ remaining: meta.members.length, removed: removedView(me) });
  }

  /**
   * Owner-only; the owner can't kick itself. Removes the target and bans
   * its identity (Ruling 13) in one commit. The ban key is a sha256 of the
   * target's identity, known only once meta is read — and hashing is not
   * storage I/O, so it lets other requests in. Hence: read meta, hash,
   * then read meta again and decide only on that second read (nothing but
   * storage between it and the commit). If the memberId's holder changed in
   * between, hash again (bounded).
   */
  private async kick(req: KickRequest): Promise<Response> {
    let hashed = null as { ident: string; key: string } | null;
    for (let attempt = 0; attempt < 3; attempt++) {
      const meta = await this.getMeta();
      if (!meta) return this.json({ error: "not_found" }, 404);
      const me = this.authorize(meta, req.caller);
      if (me instanceof Response) return me;
      if (me.memberId !== meta.ownerMemberId) return this.json({ error: "not_owner" }, 403);
      if (req.targetMemberId === me.memberId) return this.json({ error: "kick_self" }, 400);
      const target = meta.members.find((m) => m.memberId === req.targetMemberId);
      if (!target) return this.json({ removed: null });
      const ident = identityOf(target);
      if (hashed?.ident !== ident) {
        hashed = { ident, key: `ban:${await sha256Hex(ident)}` };
        continue; // `meta` is stale now — read it again
      }
      await this.removeMember(meta, target.memberId, "kick", { by: me.memberId, extraWrites: { [hashed.key]: 1 } });
      return this.json({ removed: removedView(target) });
    }
    return this.json({ error: "busy" }, 503);
  }

  /**
   * Takes one member out of the room — see removeMembers.
   * `reason`: "leave" (own choice), "kick" (by the owner, `opts.by`), or
   * "replace" (same identity rejoined from a new device, Ruling 12).
   */
  async removeMember(meta: GroupMeta, memberId: string, reason: RemoveReason, opts: RemoveOpts = {}): Promise<GroupMember | null> {
    const [m] = await this.removeMembers(meta, [memberId], reason, opts);
    return m ?? null;
  }

  /**
   * Removes members in ONE commit together with `opts.before` / `opts.after`
   * events and `opts.extraWrites`: drops every wrap (all epochs), ticket and
   * push stamp they hold, writes a `leave` (or, for kicks, a `kick` with
   * targetMemberId) per member, sets rotationDue for leave/kick (not for a
   * replacement — same person, same keys), and hands ownership on when the
   * owner leaves (Ruling 11: earliest-joined remaining account member; none
   * → room closes, ownerMemberId null; the `leave` event carries the new
   * ownerMemberId). Their sockets are closed 4003 after the commit. If no
   * member is left, the whole room is wiped instead. Never bans (kick
   * passes its ban key in extraWrites). Awaits storage only.
   */
  private async removeMembers(meta: GroupMeta, memberIds: string[], reason: RemoveReason, opts: RemoveOpts = {}): Promise<GroupMember[]> {
    const ids = new Set(memberIds);
    const removed = meta.members.filter((m) => ids.has(m.memberId));
    const events: NewEvent[] = [...(opts.before ?? [])];
    if (removed.length === 0 && events.length === 0 && !opts.after?.length) return [];
    meta.members = meta.members.filter((m) => !ids.has(m.memberId));
    if (meta.members.length === 0) {
      await this.wipe();
      return removed;
    }
    const now = this.now();
    for (const m of removed) {
      const seq = meta.seq + events.length + 1;
      const ev: NewEvent = reason === "kick"
        ? { eventId: `srv:kick:${m.memberId}:${seq}`, type: "kick", authorMemberId: opts.by ?? "", targetMemberId: m.memberId, epoch: meta.epoch, createdAt: now }
        : { eventId: `srv:leave:${m.memberId}:${seq}`, type: "leave", authorMemberId: m.memberId, epoch: meta.epoch, createdAt: now };
      if (meta.ownerMemberId === m.memberId) {
        // Only a leave gets here: kick_self is refused, and a replacement
        // moves ownership to the new memberId before calling.
        const heir = meta.members.filter((x) => x.kind === "account").reduce<GroupMember | null>((a, b) => (a && a.joinedAt <= b.joinedAt ? a : b), null);
        meta.ownerMemberId = heir?.memberId ?? null;
        if (heir) ev.ownerMemberId = heir.memberId;
        else meta.state = "closed";
      }
      events.push(ev);
    }
    if (removed.length && reason !== "replace") meta.rotationDue = true;
    events.push(...(opts.after ?? []));
    const deletes = removed.length ? await this.memberKeys(removed, reason) : [];
    await this.appendEvent(meta, events, opts.extraWrites, deletes);
    for (const m of removed) {
      this.closeMember(m.memberId);
      this.postTimes.delete(m.memberId);
    }
    return removed;
  }

  /** The last member left: close every socket and delete everything (alarm included). */
  private async wipe(): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) {
      try { ws.close(4003, "removed"); } catch { /* already closing */ }
    }
    this.postTimes.clear();
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }

  // ---- websocket ---------------------------------------------------------------
  private async issueTicket(meta: GroupMeta, caller: Caller, ticket: string, hash: string): Promise<Response> {
    const me = this.authorize(meta, caller);
    if (me instanceof Response) return me;
    const expiresAt = this.now() + GROUP_LIMITS.ticketTtlMs;
    const rec: TicketRecord = { memberId: me.memberId, exp: expiresAt };
    await this.ctx.storage.put(`tkt:${hash}`, rec);
    return this.json({ ticket, expiresAt });
  }

  /** GET /ws?ticket= — consumes the ticket and accepts a hibernating socket. */
  private async upgrade(request: Request, url: URL): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") return this.json({ error: "bad_request" }, 400);
    const ticket = url.searchParams.get("ticket") ?? "";
    const hash = TICKET_RE.test(ticket) ? await sha256Hex(ticket) : null;
    const meta = await this.getMeta();
    if (!meta) return this.json({ error: "not_found" }, 404);
    const denied = () => this.json({ error: "denied" }, 403);
    if (!hash) return denied();
    const key = `tkt:${hash}`;
    const rec = await this.ctx.storage.get<TicketRecord>(key);
    if (!rec) return denied();
    await this.ctx.storage.delete(key); // single use, even when it fails below
    const now = this.now();
    if (rec.exp < now || !meta.members.some((m) => m.memberId === rec.memberId)) return denied();

    // At most socketsPerMember per member: the oldest makes room.
    const mine = this.openSockets(rec.memberId);
    if (mine.length >= GROUP_LIMITS.socketsPerMember) {
      const oldest = mine.reduce((a, b) => (this.att(b).connectedAt < this.att(a).connectedAt ? b : a));
      try { oldest.close(4000, "replaced"); } catch { /* already closing */ }
    }

    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, [rec.memberId]);
    const att: SocketAtt = { memberId: rec.memberId, connectedAt: now, last: now };
    server.serializeAttachment(att);
    // The alarm doubles as the 2 h reaper, so make sure it fires by then.
    const cap = now + GROUP_LIMITS.hardCapMs;
    const alarm = await this.ctx.storage.getAlarm();
    if (alarm === null || alarm > cap) await this.ctx.storage.setAlarm(cap);
    return new Response(null, { status: 101, webSocket: client });
  }

  private att(ws: WebSocket): SocketAtt {
    try {
      const a = ws.deserializeAttachment() as SocketAtt | null;
      if (a && typeof a.connectedAt === "number") return a;
    } catch { /* closed */ }
    return { memberId: "", connectedAt: 0, last: 0 };
  }

  /** Sockets that are actually open (CLOSING ones don't count). */
  private openSockets(memberId?: string): WebSocket[] {
    return this.ctx.getWebSockets(memberId).filter((s) => s.readyState === WS_OPEN);
  }

  private expired(ws: WebSocket, now: number): boolean {
    return now - this.att(ws).connectedAt >= GROUP_LIMITS.hardCapMs;
  }

  /** Closes every socket past the 2 h cap; returns the ones still alive. */
  private reapExpired(now: number): WebSocket[] {
    const alive: WebSocket[] = [];
    for (const ws of this.openSockets()) {
      if (this.expired(ws, now)) {
        try { ws.close(4001, "expired"); } catch { /* already closing */ }
      } else {
        alive.push(ws);
      }
    }
    return alive;
  }

  /** Closes a removed member's sockets (tagged with its memberId). */
  closeMember(memberId: string): void {
    for (const ws of this.ctx.getWebSockets(memberId)) {
      try { ws.close(4003, "removed"); } catch { /* already closing */ }
    }
  }

  /** Sends `ev` to every live socket; ones past 2 h are closed instead. */
  broadcast(ev: GroupEvent): void {
    const frame = JSON.stringify({ t: "ev", e: ev });
    for (const ws of this.reapExpired(this.now())) {
      try { ws.send(frame); } catch { /* socket gone */ }
    }
  }

  /** An open socket, within its 2 h, heard from (frame or ping) in the last 90 s. */
  isConnected(memberId: string): boolean {
    const now = this.now();
    return this.openSockets(memberId).some((ws) => {
      if (this.expired(ws, now)) return false;
      const a = this.att(ws);
      const auto = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0;
      return now - Math.max(a.last, auto, a.connectedAt) <= GROUP_LIMITS.staleMs;
    });
  }

  // Frames from clients are never parsed or logged — only "heard from now".
  async webSocketMessage(ws: WebSocket, _message: string | ArrayBuffer): Promise<void> {
    try { ws.serializeAttachment({ ...this.att(ws), last: this.now() }); } catch { /* closing */ }
  }

  async webSocketClose(ws: WebSocket, _code: number, _reason: string, _wasClean: boolean): Promise<void> {
    try { ws.close(1000, ""); } catch { /* already closed */ }
  }

  async webSocketError(ws: WebSocket, _error: unknown): Promise<void> {
    try { ws.close(1011, ""); } catch { /* already closed */ }
  }

  // ---- maintenance alarm -------------------------------------------------------
  /**
   * Daily (and at each socket's 2 h mark): drops events older than 90 days
   * (≤ 1,000 a run, retrying in a minute while more remain), expired
   * tickets, sockets past 2 h, and wraps of epochs that no retained event
   * uses and that aren't current.
   */
  async alarm(): Promise<void> {
    const meta = await this.getMeta();
    if (!meta) return;
    const now = this.now();
    const cutoff = now - GROUP_LIMITS.retentionMs;

    const scan = await this.ctx.storage.list<GroupEvent>({ prefix: "ev:", startAfter: evKey(meta.firstSeq - 1), limit: ALARM_PRUNE_BATCH + 1 });
    const deletes: string[] = [];
    let pruned = 0;
    let oldestKept: GroupEvent | undefined;
    for (const [k, ev] of scan) {
      if (pruned >= ALARM_PRUNE_BATCH || ev.createdAt >= cutoff) { oldestKept = ev; break; }
      deletes.push(k);
      if (!ev.eventId.startsWith("srv:")) deletes.push(`eid:${ev.eventId}`);
      meta.firstSeq = ev.seq + 1;
      pruned++;
    }
    const more = pruned >= ALARM_PRUNE_BATCH && oldestKept !== undefined && oldestKept.createdAt < cutoff;

    for (const [k, t] of await this.ctx.storage.list<TicketRecord>({ prefix: "tkt:" })) {
      if (t.exp < now) deletes.push(k);
    }
    const keepFrom = Math.min(oldestKept?.epoch ?? meta.epoch, meta.epoch);
    for (const k of (await this.ctx.storage.list({ prefix: "key:" })).keys()) {
      if (Number(k.slice(4, 14)) < keepFrom) deletes.push(k);
    }

    const ops: Promise<unknown>[] = chunks(deletes).map((d) => this.ctx.storage.delete(d));
    if (pruned > 0) ops.push(this.ctx.storage.put("meta", meta));
    await Promise.all(ops);

    let next = more ? now + ALARM_RETRY_MS : now + DAY_MS;
    for (const ws of this.reapExpired(now)) next = Math.min(next, this.att(ws).connectedAt + GROUP_LIMITS.hardCapMs);
    await this.ctx.storage.setAlarm(next);
  }
}
