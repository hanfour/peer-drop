// Drives the /v3/diaries* HTTP routes end-to-end (auth, D1 indexing, rate
// limiting, cross-account flows) — the turn-order/event-validation
// mechanics themselves are pinned down directly against the DiaryRoom DO in
// diary-room.spec.ts.
import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import {
  makeAccount, bearer, newDiaryId, fakeCipher,
  createDiary, createDiaryOk, getDiary, listDiaries,
  joinByLink, joinByCode, leaveDiary, closeDiary, resetInvite,
  getEvents, postEvent, requestKey, reportEvent, postEntryOk,
} from "./diaryHelpers";
import type { TestAccount } from "./diaryHelpers";
import type { DiaryMeta } from "../diaryRoom";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

const ANALYTICS_KEY = "test-analytics-key-67890";
let devCounter = 0;
async function mkAccount(tag: string): Promise<TestAccount> {
  return makeAccount(`dev-diary-${tag}-${String(++devCounter).padStart(4, "0")}`);
}

/** Same-letter/digit-count shape, lowercased + dashed, with a confusable substitution when the code has a '0' or '1' — what a human retyping the code from a screen might produce. */
function mangleCode(code: string): string {
  let m = `${code.slice(0, 4)}-${code.slice(4)}`.toLowerCase();
  if (code.includes("0")) m = m.replace("0", "o");
  else if (code.includes("1")) m = m.replace("1", "i");
  return m;
}

describe("POST /v3/diaries — create", () => {
  it("201 on first create; idempotent 200 resend by the same owner keeps inviteCode/metaCipher; 409 diary_exists for a different owner; both D1 rows exist", async () => {
    const a = await mkAccount("create-a"), b = await mkAccount("create-b");
    const diaryId = newDiaryId();
    const metaCipher = fakeCipher();
    const r1 = await createDiary(bearer(a), diaryId, metaCipher);
    expect(r1.status).toBe(201);
    const { inviteCode } = await r1.json() as { diaryId: string; inviteCode: string };

    const r2 = await createDiary(bearer(a), diaryId, fakeCipher(999));
    expect(r2.status).toBe(200);
    expect((await r2.json() as { inviteCode: string }).inviteCode).toBe(inviteCode);

    const r3 = await createDiary(bearer(b), diaryId, fakeCipher());
    expect(r3.status).toBe(409);
    expect(await r3.json()).toEqual({ error: "diary_exists" });

    const memberRow = await env.ACCOUNTS_DB.prepare("SELECT 1 AS x FROM diary_members WHERE account_id = ?1 AND diary_id = ?2").bind(a.accountId, diaryId).first();
    expect(memberRow).toBeTruthy();
    const inviteRow = await env.ACCOUNTS_DB.prepare("SELECT 1 AS x FROM diary_invites WHERE invite_code = ?1 AND diary_id = ?2").bind(inviteCode, diaryId).first();
    expect(inviteRow).toBeTruthy();
  });

  it("rejects a non-26-char diary id with 400", async () => {
    const a = await mkAccount("create-badid");
    const r = await createDiary(bearer(a), "not-a-valid-ulid", fakeCipher());
    expect(r.status).toBe(400);
  });

  it("refuses a 21st diary with 409 diary_limit", async () => {
    const a = await mkAccount("create-limit");
    for (let i = 0; i < 20; i++) expect((await createDiary(bearer(a), newDiaryId(), fakeCipher())).status).toBe(201);
    const r21 = await createDiary(bearer(a), newDiaryId(), fakeCipher());
    expect(r21.status).toBe(409);
    expect(await r21.json()).toEqual({ error: "diary_limit" });
  });

  it("refuses a 21st create in the same UTC day with 429 rate_limited even after every earlier diary was left, and never wakes the DO", async () => {
    const a = await mkAccount("create-quota");
    const ids: string[] = [];
    for (let i = 0; i < 20; i++) {
      const id = newDiaryId();
      expect((await createDiary(bearer(a), id, fakeCipher())).status).toBe(201);
      ids.push(id);
    }
    // Leave them all, so `underDiaryLimit` sees zero current memberships:
    // the only thing that can still refuse the next create is the daily
    // quota — which is exactly the hole this closes (create/leave/create…
    // was otherwise unlimited).
    for (const id of ids) expect((await leaveDiary(bearer(a), id)).status).toBe(204);

    const blockedId = newDiaryId();
    const r21 = await createDiary(bearer(a), blockedId, fakeCipher());
    expect(r21.status).toBe(429);
    expect(await r21.json()).toEqual({ error: "rate_limited" });
    const stub = env.DIARY_ROOM.get(env.DIARY_ROOM.idFromName(blockedId));
    await runInDurableObject(stub, async (_instance, state) => {
      expect(await state.storage.get("meta")).toBeUndefined();
    });
  });
});

describe("GET /v3/diaries", () => {
  it("lists this account's diaries", async () => {
    const a = await mkAccount("list-a");
    const { diaryId: d1 } = await createDiaryOk(a);
    const { diaryId: d2 } = await createDiaryOk(a);
    const rows = await (await listDiaries(bearer(a))).json() as { diaryId: string; joinedAt: number }[];
    expect(rows.map((r) => r.diaryId).sort()).toEqual([d1, d2].sort());
  });
});

describe("GET /v3/diaries/:id — unknown id", () => {
  it("404s an id nobody created, without ever waking its DO", async () => {
    const a = await mkAccount("get404");
    const diaryId = newDiaryId();
    expect((await getDiary(bearer(a), diaryId)).status).toBe(404);
    const stub = env.DIARY_ROOM.get(env.DIARY_ROOM.idFromName(diaryId));
    await runInDurableObject(stub, async (_instance, state) => {
      expect(await state.storage.get("meta")).toBeUndefined();
    });
  });

  it("includes inviteCode only for the owner", async () => {
    const owner = await mkAccount("getid-owner"), b = await mkAccount("getid-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    const asOwner = await (await getDiary(bearer(owner), diaryId)).json() as { inviteCode?: string };
    expect(asOwner.inviteCode).toBe(inviteCode);
    const asMember = await (await getDiary(bearer(b), diaryId)).json() as { inviteCode?: string };
    expect(asMember.inviteCode).toBeUndefined();
  });
});

describe("join", () => {
  it("link join and code-only join both work; a mangled (lowercase/dashed/confusable) code still resolves", async () => {
    const owner = await mkAccount("join-ok-owner"), b = await mkAccount("join-ok-b"), c = await mkAccount("join-ok-c");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    const rLink = await joinByLink(bearer(b), diaryId, inviteCode);
    expect(rLink.status).toBe(201);
    const body = await rLink.json() as { diaryId: string; members: string[]; holderIndex: number; ownerAccountId: string; state: string; seq: number; metaCipher: string };
    expect(body).toMatchObject({ diaryId, holderIndex: 0, ownerAccountId: owner.accountId, state: "open", seq: 1 }); // seq 1 = the join event itself
    expect(body.members).toEqual([owner.accountId, b.accountId]);
    expect(typeof body.metaCipher).toBe("string");

    const rCode = await joinByCode(bearer(c), mangleCode(inviteCode));
    expect(rCode.status).toBe(201);
  });

  it("a wrong code returns 403 bad_code, then 429 after the 11th attempt in the hour", async () => {
    const a = await mkAccount("join-wrongcode");
    for (let i = 0; i < 10; i++) {
      const r = await joinByCode(bearer(a), "ZZZZZZZZ");
      expect(r.status).toBe(403);
      expect(await r.json()).toEqual({ error: "bad_code" });
    }
    expect((await joinByCode(bearer(a), "ZZZZZZZZ")).status).toBe(429);
  });

  it("re-joining as an existing member is idempotent (200) and the D1 row stays exactly one", async () => {
    const owner = await mkAccount("join-idem-owner"), b = await mkAccount("join-idem-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    expect((await joinByLink(bearer(b), diaryId, inviteCode)).status).toBe(201);
    expect((await joinByLink(bearer(b), diaryId, inviteCode)).status).toBe(200);
    const row = await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM diary_members WHERE account_id = ?1 AND diary_id = ?2").bind(b.accountId, diaryId).first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("refuses a 13th member with 409 diary_full_members", async () => {
    const owner = await mkAccount("join-full-owner");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    for (let i = 0; i < 11; i++) {
      const m = await mkAccount(`join-full-m${i}`);
      expect((await joinByLink(bearer(m), diaryId, inviteCode)).status).toBe(201);
    }
    const extra = await mkAccount("join-full-extra");
    const r = await joinByLink(bearer(extra), diaryId, inviteCode);
    expect(r.status).toBe(409);
    expect(await r.json()).toEqual({ error: "diary_full_members" });
  });

  it("refuses a join once the caller already participates in 20 diaries", async () => {
    const owner = await mkAccount("join-limit-owner"), caller = await mkAccount("join-limit-caller");
    for (let i = 0; i < 20; i++) expect((await createDiary(bearer(caller), newDiaryId(), fakeCipher())).status).toBe(201);
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    const r = await joinByLink(bearer(caller), diaryId, inviteCode);
    expect(r.status).toBe(409);
    expect(await r.json()).toEqual({ error: "diary_limit" });
  });

  it("refuses to join a closed diary with 403 diary_closed", async () => {
    const owner = await mkAccount("join-closed-owner"), b = await mkAccount("join-closed-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    expect((await closeDiary(bearer(owner), diaryId)).status).toBe(204);
    const r = await joinByLink(bearer(b), diaryId, inviteCode);
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "diary_closed" });
  });

  it("closed wins over the caller's own 20-diary cap — a caller already at 20 diaries still gets diary_closed, not diary_limit", async () => {
    const owner = await mkAccount("closed-vs-cap-owner"), caller = await mkAccount("closed-vs-cap-caller");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    expect((await closeDiary(bearer(owner), diaryId)).status).toBe(204);
    for (let i = 0; i < 20; i++) expect((await createDiary(bearer(caller), newDiaryId(), fakeCipher())).status).toBe(201);
    const r = await joinByLink(bearer(caller), diaryId, inviteCode);
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "diary_closed" });
  });

  it("after invite/reset, the old code fails on both join routes even if a stale D1 diary_invites row still points at this diary", async () => {
    const owner = await mkAccount("reset-stale-owner"), b = await mkAccount("reset-stale-b"), c = await mkAccount("reset-stale-c");
    const { diaryId, inviteCode: oldCode } = await createDiaryOk(owner);
    const rReset = await resetInvite(bearer(owner), diaryId);
    const { inviteCode: newCode } = await rReset.json() as { inviteCode: string };
    // Simulate a stale row for the OLD code that a prior request's D1 write left behind (or a race re-inserted).
    await env.ACCOUNTS_DB.prepare("INSERT OR IGNORE INTO diary_invites (invite_code, diary_id) VALUES (?1, ?2)").bind(oldCode, diaryId).run();

    const rCode = await joinByCode(bearer(b), oldCode);
    expect(rCode.status).toBe(403);
    expect(await rCode.json()).toEqual({ error: "bad_code" });

    const rLink = await joinByLink(bearer(c), diaryId, oldCode);
    expect(rLink.status).toBe(403);
    expect(await rLink.json()).toEqual({ error: "bad_code" });

    expect((await joinByLink(bearer(c), diaryId, newCode)).status).toBe(201);
  });
});

describe("member-only routes", () => {
  it("a non-member gets 403 not_member from GET events, report and request-key", async () => {
    const owner = await mkAccount("member-only-owner"), outsider = await mkAccount("member-only-outsider");
    const { diaryId } = await createDiaryOk(owner);
    const seq = await postEntryOk(bearer(owner), diaryId);
    const rEvents = await getEvents(bearer(outsider), diaryId);
    expect(rEvents.status).toBe(403);
    expect(await rEvents.json()).toEqual({ error: "not_member" });
    const rReqKey = await requestKey(bearer(outsider), diaryId);
    expect(rReqKey.status).toBe(403);
    expect(await rReqKey.json()).toEqual({ error: "not_member" });
    const rReport = await reportEvent(bearer(outsider), diaryId, seq, { reason: "spam" });
    expect(rReport.status).toBe(403);
    expect(await rReport.json()).toEqual({ error: "not_member" });
  });
});

describe("request-key", () => {
  it("204s for a current member and rate-limits at 6/hour", async () => {
    const owner = await mkAccount("reqkey-owner"), b = await mkAccount("reqkey-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    for (let i = 0; i < 6; i++) expect((await requestKey(bearer(b), diaryId)).status).toBe(204);
    expect((await requestKey(bearer(b), diaryId)).status).toBe(429);
  });
});

describe("leave / close / invite-reset — D1 side effects", () => {
  it("leave deletes the D1 row (204); a non-member leave is an idempotent 204 no-op", async () => {
    const owner = await mkAccount("leave-http-owner"), b = await mkAccount("leave-http-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    expect((await leaveDiary(bearer(b), diaryId)).status).toBe(204);
    const row = await env.ACCOUNTS_DB.prepare("SELECT 1 AS x FROM diary_members WHERE account_id = ?1 AND diary_id = ?2").bind(b.accountId, diaryId).first();
    expect(row).toBeNull();
    expect((await leaveDiary(bearer(b), diaryId)).status).toBe(204);
  });

  it("the LAST member leaving also drops the diary's diary_invites row, so its code stops resolving", async () => {
    const owner = await mkAccount("leave-last-owner"), b = await mkAccount("leave-last-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    expect((await joinByLink(bearer(b), diaryId, inviteCode)).status).toBe(201);

    const inviteRow = () => env.ACCOUNTS_DB.prepare("SELECT 1 AS x FROM diary_invites WHERE diary_id = ?1").bind(diaryId).first();
    // Not the last one out — the invite row must survive.
    expect((await leaveDiary(bearer(b), diaryId)).status).toBe(204);
    expect(await inviteRow()).toBeTruthy();

    // Owner is now the last member; the emptied diary's code is garbage.
    expect((await leaveDiary(bearer(owner), diaryId)).status).toBe(204);
    expect(await inviteRow()).toBeNull();

    // With both index tables empty the id no longer exists at all...
    expect((await joinByLink(bearer(b), diaryId, inviteCode)).status).toBe(404);
    // ...and the short code resolves to nothing (the ordinary bad-code path).
    const rCode = await joinByCode(bearer(b), inviteCode);
    expect(rCode.status).toBe(403);
    expect(await rCode.json()).toEqual({ error: "bad_code" });
  });

  it("close is owner-only; afterwards join and POST events 403 diary_closed, but GET meta/events still work", async () => {
    const owner = await mkAccount("close-http-owner"), b = await mkAccount("close-http-b"), outsider = await mkAccount("close-http-outsider");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    expect((await closeDiary(bearer(b), diaryId)).status).toBe(403);
    expect((await closeDiary(bearer(owner), diaryId)).status).toBe(204);
    expect((await joinByLink(bearer(outsider), diaryId, inviteCode)).status).toBe(403);
    const rClosedEvent = await postEvent(bearer(owner), diaryId, { type: "pass" });
    expect(rClosedEvent.status).toBe(403);
    expect(await rClosedEvent.json()).toEqual({ error: "diary_closed" });
    expect((await getDiary(bearer(owner), diaryId)).status).toBe(200);
    expect((await getEvents(bearer(owner), diaryId)).status).toBe(200);
    // leave still works once closed, and still deletes the D1 row.
    expect((await leaveDiary(bearer(b), diaryId)).status).toBe(204);
    const row = await env.ACCOUNTS_DB.prepare("SELECT 1 AS x FROM diary_members WHERE account_id = ?1 AND diary_id = ?2").bind(b.accountId, diaryId).first();
    expect(row).toBeNull();
  });

  it("invite reset: the old code stops working, the new one works, and D1 keeps only the new code", async () => {
    const owner = await mkAccount("reset-http-owner"), b = await mkAccount("reset-http-b");
    const { diaryId, inviteCode: oldCode } = await createDiaryOk(owner);
    const r = await resetInvite(bearer(owner), diaryId);
    expect(r.status).toBe(200);
    const { inviteCode: newCode } = await r.json() as { inviteCode: string };
    expect(newCode).not.toBe(oldCode);
    const rOld = await joinByCode(bearer(b), oldCode);
    expect(rOld.status).toBe(403);
    expect(await rOld.json()).toEqual({ error: "bad_code" });
    expect((await joinByLink(bearer(b), diaryId, newCode)).status).toBe(201);
    const oldRow = await env.ACCOUNTS_DB.prepare("SELECT 1 AS x FROM diary_invites WHERE invite_code = ?1").bind(oldCode).first();
    expect(oldRow).toBeNull();
    const newRow = await env.ACCOUNTS_DB.prepare("SELECT 1 AS x FROM diary_invites WHERE invite_code = ?1 AND diary_id = ?2").bind(newCode, diaryId).first();
    expect(newRow).toBeTruthy();
  });
});

describe("POST .../events — HTTP wiring and raw body size", () => {
  it("round-trips entry/comment/like/pass with correct status codes and holderIndex forwarding", async () => {
    const owner = await mkAccount("events-http-owner"), b = await mkAccount("events-http-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    const seq = await postEntryOk(bearer(owner), diaryId);
    expect((await postEvent(bearer(b), diaryId, { type: "comment", refSeq: seq, payloadCipher: fakeCipher() })).status).toBe(201);
    expect((await postEvent(bearer(b), diaryId, { type: "like", refSeq: seq })).status).toBe(201);
    const rPass = await postEvent(bearer(owner), diaryId, { type: "pass" });
    expect(rPass.status).toBe(201);
    expect((await rPass.json() as { holderIndex: number }).holderIndex).toBe(1);
    const rEvents = await getEvents(bearer(owner), diaryId);
    expect(rEvents.status).toBe(200);
    expect(((await rEvents.json()) as { events: unknown[] }).events.length).toBe(5); // join, entry, comment, like, pass
  });

  it("projects the response to exactly {seq, holderIndex} for both a fresh (201) and an idempotent resend (200) — no event/meta/inviteCode leak to other members", async () => {
    const owner = await mkAccount("proj-owner"), b = await mkAccount("proj-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    const eventId = "01PROJEVENT0000000000001A";

    const r1 = await postEvent(bearer(owner), diaryId, { eventId, type: "pass" });
    expect(r1.status).toBe(201);
    const body1 = await r1.json() as Record<string, unknown>;
    expect(Object.keys(body1).sort()).toEqual(["holderIndex", "seq"]);
    expect(JSON.stringify(body1)).not.toContain(inviteCode);

    const r2 = await postEvent(bearer(owner), diaryId, { eventId, type: "pass" }); // idempotent resend
    expect(r2.status).toBe(200);
    const body2 = await r2.json() as Record<string, unknown>;
    expect(Object.keys(body2).sort()).toEqual(["holderIndex", "seq"]);
    expect(JSON.stringify(body2)).not.toContain(inviteCode);
  });

  it("rejects a raw body over 96 KB with 413", async () => {
    const owner = await mkAccount("bodysize-owner");
    const { diaryId } = await createDiaryOk(owner);
    const huge = "x".repeat(97 * 1024);
    const r = await SELF.fetch(`https://example.com/v3/diaries/${diaryId}/events`, {
      method: "POST", headers: bearer(owner), body: JSON.stringify({ eventId: "x", type: "entry", payloadCipher: huge }),
    });
    expect(r.status).toBe(413);
  });
});

describe("report", () => {
  it("writes diary_id/diary_seq/sender_hash of the entry's author, inbox_item_id NULL; readable via admin with the new fields; shares the 20/day quota", async () => {
    const owner = await mkAccount("report-owner"), b = await mkAccount("report-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    const seq = await postEntryOk(bearer(owner), diaryId);
    const since = Date.now() - 1;
    const r = await reportEvent(bearer(b), diaryId, seq, { reason: "harassment", excerpt: "some decrypted text" });
    expect(r.status).toBe(201);
    const { id: reportId } = await r.json() as { id: string };

    const admin = await SELF.fetch(`https://example.com/v3/admin/reports?since=${since}`, { headers: { "X-API-Key": ANALYTICS_KEY } });
    expect(admin.status).toBe(200);
    const { reports } = await admin.json() as { reports: { id: string; reporterAccountId: string; senderHash: string | null; inboxItemId: string | null; diaryId: string | null; diarySeq: number | null; reason: string }[] };
    const mine = reports.find((x) => x.id === reportId)!;
    expect(mine.reporterAccountId).toBe(b.accountId);
    expect(mine.inboxItemId).toBeNull();
    expect(mine.diaryId).toBe(diaryId);
    expect(mine.diarySeq).toBe(seq);
    expect(mine.senderHash).toMatch(/^[0-9a-f]{64}$/);

    await env.V2_STORE.put(`report-quota:${b.accountId}:${new Date().toISOString().slice(0, 10)}`, "20");
    expect((await reportEvent(bearer(b), diaryId, seq, { reason: "spam" })).status).toBe(429);
  });

  it("404s reporting a nonexistent seq", async () => {
    const owner = await mkAccount("report-404-owner");
    const { diaryId } = await createDiaryOk(owner);
    expect((await reportEvent(bearer(owner), diaryId, 999, { reason: "spam" })).status).toBe(404);
  });
});

describe("invite code D1 collision", () => {
  it("regenerates the invite code when INSERT OR IGNORE silently no-ops on a primary-key collision with another diary's code", async () => {
    const victim = await mkAccount("collide-victim");
    const { diaryId: victimDiaryId } = await createDiaryOk(victim);
    const FORCED_CODE = "ZZZZZZZ1"; // a syntactically valid 8-char code from ACCOUNT_ID_ALPHABET
    await env.ACCOUNTS_DB.prepare("INSERT INTO diary_invites (invite_code, diary_id) VALUES (?1, ?2)").bind(FORCED_CODE, victimDiaryId).run();

    const owner = await mkAccount("collide-owner");
    const diaryId = newDiaryId();
    // Seed the DO's meta directly (bypassing /init's random generateAccountId())
    // so its minted inviteCode collides with the victim's — forcing the same
    // code the real generator would only ever hit by astronomical chance.
    const stub = env.DIARY_ROOM.get(env.DIARY_ROOM.idFromName(diaryId));
    await runInDurableObject(stub, async (_instance, state) => {
      const meta: DiaryMeta = {
        diaryId, ownerAccountId: owner.accountId, members: [owner.accountId], holderIndex: 0, seq: 0,
        inviteCode: FORCED_CODE, state: "open", keyEpoch: 1, metaCipher: "seed-cipher", createdAt: Date.now(), bytesUsed: 0,
      };
      await state.storage.put("meta", meta);
    });

    const r = await createDiary(bearer(owner), diaryId, "seed-cipher");
    expect(r.status).toBe(200); // meta already existed (seeded above) with this owner -> idempotent /init path
    const { inviteCode: finalCode } = await r.json() as { inviteCode: string };
    expect(finalCode).not.toBe(FORCED_CODE);

    // The regenerated code actually resolves to OUR diary, both via D1 and the DO.
    const joiner = await mkAccount("collide-joiner");
    expect((await joinByCode(bearer(joiner), finalCode)).status).toBe(201);
    const row = await env.ACCOUNTS_DB.prepare("SELECT diary_id FROM diary_invites WHERE invite_code = ?1").bind(finalCode).first<{ diary_id: string }>();
    expect(row?.diary_id).toBe(diaryId);
    // The victim's own (still-colliding) code is untouched and still theirs.
    const victimRow = await env.ACCOUNTS_DB.prepare("SELECT diary_id FROM diary_invites WHERE invite_code = ?1").bind(FORCED_CODE).first<{ diary_id: string }>();
    expect(victimRow?.diary_id).toBe(victimDiaryId);
  });
});

describe("migration 0003_diary", () => {
  it("allows reports.sender_hash / inbox_item_id to be NULL directly, and existing notes reports keep working (see notes-inbox.spec.ts)", async () => {
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO reports (id, reporter_account_id, sender_hash, inbox_item_id, diary_id, diary_seq, reason, excerpt, created_at) VALUES (?1, ?2, NULL, NULL, ?3, ?4, ?5, NULL, ?6)",
    ).bind("rpt-null-test-0001", "ACCT0001", "diary00000000000000000001", 1, "other", Date.now()).run();
    const row = await env.ACCOUNTS_DB.prepare("SELECT sender_hash, inbox_item_id FROM reports WHERE id = ?1").bind("rpt-null-test-0001").first<{ sender_hash: string | null; inbox_item_id: string | null }>();
    expect(row).toEqual({ sender_hash: null, inbox_item_id: null });
  });
});
