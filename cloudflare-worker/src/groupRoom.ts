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
//   tkt:<sha256hex(ticket)>       → WebSocket ticket (later task)
//   push:<memberId>               → push throttle stamp (later task)
//
// D1 (group_members / group_invites) is only an index — the live membership
// set, invite code and key epochs live here. An anonymous member's deviceId
// exists ONLY in this DO's `meta` and never leaves it in any response; an
// account member has no deviceId here at all (Ruling 14).
//
// Every endpoint except /init answers 404 without touching storage when there
// is no `meta`, so a stray id can never materialise a room.
import { generateAccountId } from "./account";
import { decodedByteLength, isValidGroupId, isValidMemberId, sha256Hex } from "./groupSig";

export type GroupMemberKind = "account" | "anon";
export type JoinPolicy = "accountOnly" | "anonymousAllowed";
// account 成員：有 accountId、沒有 deviceId；anon 成員：有 deviceId、沒有 accountId（Ruling 14）
export interface GroupMember { memberId: string; kind: GroupMemberKind; accountId?: string; deviceId?: string; joinedAt: number; joinedEpoch: number; pubKey: string; pubKeySig?: string }
export type PushRecipient = { kind: "account"; accountId: string } | { kind: "device"; deviceId: string };
export interface GroupMeta { groupId: string; ownerMemberId: string | null; members: GroupMember[]; joinPolicy: JoinPolicy; discoverability: "private"; state: "open" | "closed"; epoch: number; seq: number; firstSeq: number; inviteCode: string; metaVersion: number; rotationDue: boolean; createdAt: number }
export type GroupEventType = "msg" | "join" | "leave" | "kick" | "meta";
export interface GroupEvent { seq: number; eventId: string; type: GroupEventType; authorMemberId: string; epoch: number; payloadCipher?: string; targetMemberId?: string; ownerMemberId?: string; createdAt: number }
export interface WrapRecord { wrapped: string; wrappedBy: string; sig: string; createdAt: number }
export interface Caller { memberId: string; accountId: string | null; deviceId: string; lane: "bearer" | "key" }
export interface PublicMember { memberId: string; kind: GroupMemberKind; accountId?: string; joinedAt: number; pubKey: string; pubKeySig?: string; hasKey: boolean }
export const GROUP_LIMITS = { maxMembers: 50, maxEvents: 5000, retentionMs: 90 * 86_400_000, maxPayloadBytes: 8 * 1024, maxMetaBytes: 400 * 1024, wrappedBytes: 92, sigBytes: 64, pubKeyBytes: 32, ticketTtlMs: 60_000, socketsPerMember: 2, staleMs: 90_000, hardCapMs: 2 * 3600_000, pushThrottleMs: 60_000, eventsDefaultLimit: 100, eventsMaxLimit: 500, msgsPerMinutePerMember: 30 } as const;

const DAY_MS = 86_400_000;
const JOIN_POLICIES = new Set<string>(["accountOnly", "anonymousAllowed"]);

const padSeq = (n: number): string => String(n).padStart(12, "0");
const evKey = (seq: number): string => `ev:${padSeq(seq)}`;
const keyKey = (epoch: number, memberId: string): string => `key:${String(epoch).padStart(10, "0")}:${memberId}`;
const banHash = (m: { kind: GroupMemberKind; accountId?: string; deviceId?: string }): Promise<string> =>
  sha256Hex(m.kind === "account" ? `acct:${m.accountId}` : `dev:${m.deviceId}`);

class BadRequest extends Error {}

const isNonEmptyString = (v: unknown): v is string => typeof v === "string" && v.length > 0;
/** True when `v` is base64 decoding to exactly `n` bytes. */
const isB64Bytes = (v: unknown, n: number): v is string => typeof v === "string" && decodedByteLength(v) === n;

function parseCaller(v: unknown): Caller {
  const c = v as Partial<Caller> | null;
  if (!c || typeof c !== "object") throw new BadRequest();
  if (!isNonEmptyString(c.memberId) || !isNonEmptyString(c.deviceId)) throw new BadRequest();
  if (c.accountId !== null && !isNonEmptyString(c.accountId)) throw new BadRequest();
  if (c.lane !== "bearer" && c.lane !== "key") throw new BadRequest();
  return { memberId: c.memberId, accountId: c.accountId, deviceId: c.deviceId, lane: c.lane };
}

/**
 * Builds a member from an untrusted join body, copying only the fields its
 * kind allows. An account member carrying a deviceId is rejected outright
 * (this DO never stores an account member's device — Ruling 14).
 */
function parseJoinMember(v: unknown, now: number, epoch: number): GroupMember {
  const m = v as Record<string, unknown> | null;
  if (!m || typeof m !== "object") throw new BadRequest();
  if (!isValidMemberId(m.memberId) || !isB64Bytes(m.pubKey, GROUP_LIMITS.pubKeyBytes)) throw new BadRequest();
  if (m.kind === "account") {
    if (!isNonEmptyString(m.accountId) || m.deviceId !== undefined) throw new BadRequest();
    if (!isB64Bytes(m.pubKeySig, GROUP_LIMITS.sigBytes)) throw new BadRequest();
    return { memberId: m.memberId, kind: "account", accountId: m.accountId, joinedAt: now, joinedEpoch: epoch, pubKey: m.pubKey, pubKeySig: m.pubKeySig };
  }
  if (m.kind === "anon") {
    if (!isNonEmptyString(m.deviceId) || m.accountId !== undefined) throw new BadRequest();
    return { memberId: m.memberId, kind: "anon", deviceId: m.deviceId, joinedAt: now, joinedEpoch: epoch, pubKey: m.pubKey };
  }
  throw new BadRequest();
}

/** Same person? Account members by accountId, anonymous ones by deviceId. */
const sameIdentity = (a: GroupMember, b: GroupMember): boolean =>
  a.kind === b.kind && (a.kind === "account" ? a.accountId === b.accountId : a.deviceId === b.deviceId);

/** A member as any other member may see it: never the deviceId. */
const stripDevice = ({ deviceId: _d, ...rest }: GroupMember): GroupMember => rest;

export class GroupRoom {
  ctx: DurableObjectState;
  /** Clock seam for tests. */
  now: () => number = () => Date.now();

  constructor(ctx: DurableObjectState, _env: unknown) {
    this.ctx = ctx;
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
    const member = meta.members.find((m) => m.memberId === caller.memberId);
    if (!member) return this.json({ error: "not_member" }, 403);
    if (member.kind === "anon") {
      if (caller.lane === "key") return this.json({ error: "bearer_required" }, 401);
      if (member.deviceId !== caller.deviceId) return this.json({ error: "not_member" }, 403);
    } else if (member.accountId !== caller.accountId) {
      return this.json({ error: "not_member" }, 403);
    }
    return member;
  }

  /**
   * Assigns the next seq(s) to `events` and commits them together with
   * `meta` and `extraWrites` in one storage.put (atomic). Client-posted
   * events also get their `eid:` idempotency entry; "srv:" ids are reserved
   * for server-written events and can never be replayed by a client.
   * (Pruning to maxEvents and WebSocket broadcast hook in here later.)
   */
  async appendEvent(
    meta: GroupMeta,
    events: Omit<GroupEvent, "seq"> | Omit<GroupEvent, "seq">[],
    extraWrites: Record<string, unknown> = {},
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
    writes.meta = meta;
    await this.ctx.storage.put(writes);
    return out;
  }

  /** Every wrapped key held by `memberId`, across all epochs. */
  private async keyKeysOf(memberId: string): Promise<string[]> {
    const all = await this.ctx.storage.list({ prefix: "key:" });
    return [...all.keys()].filter((k) => k.endsWith(`:${memberId}`));
  }

  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (request.method !== "POST") return this.json({ error: "not_found" }, 404);
    try {
      if (path === "/init") return await this.init(request);
      // Everything else requires an existing room — checked before even
      // parsing the body, and nothing below writes for a missing meta.
      const meta = await this.getMeta();
      if (!meta) return this.json({ error: "not_found" }, 404);
      const body = await request.json().catch(() => { throw new BadRequest(); }) as Record<string, unknown>;
      if (!body || typeof body !== "object") throw new BadRequest();
      switch (path) {
        case "/view": return await this.view(meta, parseCaller(body.caller));
        case "/join": return await this.join(meta, body);
        case "/close": return await this.close(meta, parseCaller(body.caller));
        case "/invite/reset": return await this.resetInvite(meta, parseCaller(body.caller));
      }
      return this.json({ error: "not_found" }, 404);
    } catch (e) {
      if (e instanceof BadRequest) return this.json({ error: "bad_request" }, 400);
      throw e;
    }
  }

  // ---- create / idempotent re-create -----------------------------------
  private async init(request: Request): Promise<Response> {
    const body = await request.json().catch(() => { throw new BadRequest(); }) as {
      groupId?: unknown; owner?: Record<string, unknown>; ownerWrap?: Record<string, unknown>;
      metaCipher?: unknown; joinPolicy?: unknown; inviteCode?: unknown;
    };
    const owner = body?.owner;
    const wrap = body?.ownerWrap;
    if (!owner || typeof owner !== "object" || !wrap || typeof wrap !== "object") throw new BadRequest();
    if (!isValidGroupId(body.groupId) || !isValidMemberId(owner.memberId) || !isNonEmptyString(owner.accountId)) throw new BadRequest();
    if (!isB64Bytes(owner.pubKey, GROUP_LIMITS.pubKeyBytes) || !isB64Bytes(owner.pubKeySig, GROUP_LIMITS.sigBytes)) throw new BadRequest();
    if (!isB64Bytes(wrap.wrapped, GROUP_LIMITS.wrappedBytes) || !isB64Bytes(wrap.sig, GROUP_LIMITS.sigBytes)) throw new BadRequest();
    if (typeof body.joinPolicy !== "string" || !JOIN_POLICIES.has(body.joinPolicy)) throw new BadRequest();
    if (body.inviteCode !== undefined && !isNonEmptyString(body.inviteCode)) throw new BadRequest();
    if (!isNonEmptyString(body.metaCipher)) throw new BadRequest();
    const metaLen = decodedByteLength(body.metaCipher);
    if (metaLen === null) throw new BadRequest();
    if (metaLen > GROUP_LIMITS.maxMetaBytes) return this.json({ error: "too_large" }, 413);

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
      joinPolicy: body.joinPolicy as JoinPolicy,
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
    await this.ctx.storage.put({ meta, metacipher: body.metaCipher, [keyKey(1, owner.memberId)]: ownerWrap });
    await this.ctx.storage.setAlarm(now + DAY_MS);
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
  private async join(meta: GroupMeta, body: Record<string, unknown>): Promise<Response> {
    const now = this.now();
    const member = parseJoinMember(body.member, now, meta.epoch);
    const dryRun = body.dryRun === true;

    const prior = meta.members.find((m) => sameIdentity(m, member));
    // Idempotent short-circuit beats every check below: an existing member
    // replaying a stale invite link needs no fresh authorization.
    if (prior && prior.memberId === member.memberId) return this.json({ added: false }, 200);
    if (await this.ctx.storage.get(`ban:${await banHash(member)}`) !== undefined) return this.json({ error: "banned" }, 403);
    // Authoritative code check (D1's group_invites only maps code → groupId).
    if (meta.inviteCode !== body.inviteCode) return this.json({ error: "bad_code" }, 403);
    if (meta.state === "closed") return this.json({ error: "group_closed" }, 403);
    if (member.kind === "anon" && meta.joinPolicy === "accountOnly") return this.json({ error: "account_required" }, 403);
    // A replacement doesn't grow the room, so the old seat doesn't count.
    if (meta.members.length - (prior ? 1 : 0) >= GROUP_LIMITS.maxMembers) return this.json({ error: "group_full_members" }, 409);
    if (meta.members.some((m) => m.memberId === member.memberId)) return this.json({ error: "member_id_taken" }, 409);
    if (dryRun) return this.json({ added: true, replaced: !!prior }, 201);

    const events: Omit<GroupEvent, "seq">[] = [];
    if (prior) {
      // Ruling 12: same identity on a new device takes over atomically —
      // old memberId out (with its wraps), new one in, ownership carried
      // over. No rotationDue: it's the same person, who already had those
      // keys. "srv:" ids embed the seq the event will get.
      const wasOwner = meta.ownerMemberId === prior.memberId;
      meta.members = meta.members.filter((m) => m.memberId !== prior.memberId);
      meta.members.push(member);
      if (wasOwner) meta.ownerMemberId = member.memberId;
      events.push({ eventId: `srv:leave:${prior.memberId}:${meta.seq + 1}`, type: "leave", authorMemberId: prior.memberId, epoch: meta.epoch, createdAt: now });
      const joinEv: Omit<GroupEvent, "seq"> = { eventId: `srv:join:${member.memberId}:${meta.seq + 2}`, type: "join", authorMemberId: member.memberId, epoch: meta.epoch, createdAt: now };
      if (wasOwner) joinEv.ownerMemberId = member.memberId;
      events.push(joinEv);
      const stale = [...await this.keyKeysOf(prior.memberId), `push:${prior.memberId}`];
      // No await between the delete and appendEvent's put: the DO coalesces
      // both into one atomic write.
      const del = this.ctx.storage.delete(stale);
      await Promise.all([del, this.appendEvent(meta, events)]);
      for (const ws of this.ctx.getWebSockets(prior.memberId)) {
        try { ws.close(4001, "replaced"); } catch { /* already closing */ }
      }
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

  // ---- daily maintenance -----------------------------------------------------
  // Retention pruning (90 days), expired tickets and orphaned old-epoch wraps
  // are added in a later task; for now this just keeps the daily cadence.
  async alarm(): Promise<void> {
    if (!(await this.getMeta())) return;
    await this.ctx.storage.setAlarm(this.now() + DAY_MS);
  }
}
