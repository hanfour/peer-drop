// Drives the DiaryRoom Durable Object directly (bypassing the /v3 HTTP
// routes and D1) — same style as notes-inbox-do.spec.ts for AccountInbox.
// This is where the turn-order arithmetic, event-type validation and the
// byte-cap accounting are pinned down precisely; diary-routes.spec.ts
// covers the HTTP-layer concerns (D1 indexing, rate limits, auth).
import { env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { ulid } from "../notes";
import { fakeCipher } from "./diaryHelpers";
import type { DiaryRoom, DiaryMeta, DiaryEvent } from "../diaryRoom";

const stubFor = (name: string) => env.DIARY_ROOM.get(env.DIARY_ROOM.idFromName(name));

async function initDiary(stub: DurableObjectStub, ownerAccountId: string, opts: { diaryId?: string; metaCipher?: string; inviteCode?: string } = {}) {
  const diaryId = opts.diaryId ?? ulid();
  const r = await stub.fetch("https://diary/init", { method: "POST", body: JSON.stringify({ diaryId, ownerAccountId, metaCipher: opts.metaCipher ?? fakeCipher(), inviteCode: opts.inviteCode }) });
  return { r, diaryId };
}
const getMeta = (stub: DurableObjectStub) => stub.fetch("https://diary/meta");
const join = (stub: DurableObjectStub, accountId: string) => stub.fetch("https://diary/join", { method: "POST", body: JSON.stringify({ accountId }) });
const leave = (stub: DurableObjectStub, accountId: string) => stub.fetch("https://diary/leave", { method: "POST", body: JSON.stringify({ accountId }) });
const close = (stub: DurableObjectStub, accountId: string) => stub.fetch("https://diary/close", { method: "POST", body: JSON.stringify({ accountId }) });
const resetInvite = (stub: DurableObjectStub, accountId: string) => stub.fetch("https://diary/invite/reset", { method: "POST", body: JSON.stringify({ accountId }) });
const getEvents = (stub: DurableObjectStub, q = "") => stub.fetch(`https://diary/events${q}`);
const postEvent = (stub: DurableObjectStub, accountId: string, body: { eventId?: string; type: string; refSeq?: number; payloadCipher?: string }) =>
  stub.fetch("https://diary/events", { method: "POST", body: JSON.stringify({ eventId: body.eventId ?? ulid(), accountId, ...body }) });
const getEvent = (stub: DurableObjectStub, seq: number) => stub.fetch(`https://diary/event/${seq}`);

describe("DiaryRoom: init", () => {
  it("creates on first call (201) and is idempotent for the same owner (200, unchanged inviteCode/metaCipher)", async () => {
    const stub = stubFor("room-init-1");
    const { r: r1, diaryId } = await initDiary(stub, "OWNER001", { metaCipher: "cipher-v1" });
    expect(r1.status).toBe(201);
    const meta1 = await r1.json() as DiaryMeta;
    expect(meta1.members).toEqual(["OWNER001"]);
    expect(meta1.holderIndex).toBe(0);
    expect(meta1.seq).toBe(0);
    expect(meta1.state).toBe("open");
    expect(meta1.keyEpoch).toBe(1);
    expect(meta1.bytesUsed).toBe(0);
    expect(meta1.metaCipher).toBe("cipher-v1");

    const { r: r2 } = await initDiary(stub, "OWNER001", { diaryId, metaCipher: "cipher-v2-ignored" });
    expect(r2.status).toBe(200);
    const meta2 = await r2.json() as DiaryMeta;
    expect(meta2.inviteCode).toBe(meta1.inviteCode);
    expect(meta2.metaCipher).toBe("cipher-v1"); // not overwritten by the resend
  });

  it("refuses a re-create by a different account with 409 diary_exists", async () => {
    const stub = stubFor("room-init-2");
    const { diaryId } = await initDiary(stub, "OWNER001");
    const { r } = await initDiary(stub, "OTHER001", { diaryId });
    expect(r.status).toBe(409);
    expect(await r.json()).toEqual({ error: "diary_exists" });
  });
});

describe("DiaryRoom: join", () => {
  it("adds a new member (201, added: true) and is idempotent for an existing member (200, added: false)", async () => {
    const stub = stubFor("room-join-1");
    await initDiary(stub, "OWNER001");
    const r1 = await join(stub, "MEMBER01");
    expect(r1.status).toBe(201);
    const b1 = await r1.json() as { added: boolean; meta: DiaryMeta };
    expect(b1.added).toBe(true);
    expect(b1.meta.members).toEqual(["OWNER001", "MEMBER01"]);

    const r2 = await join(stub, "MEMBER01");
    expect(r2.status).toBe(200);
    const b2 = await r2.json() as { added: boolean; meta: DiaryMeta };
    expect(b2.added).toBe(false);
    expect(b2.meta.members).toEqual(["OWNER001", "MEMBER01"]);
  });

  it("refuses new joins once closed (403 diary_closed) but an already-existing member still gets an idempotent 200", async () => {
    const stub = stubFor("room-join-2");
    await initDiary(stub, "OWNER001");
    await join(stub, "MEMBER01");
    await close(stub, "OWNER001");
    const rNew = await join(stub, "MEMBER02");
    expect(rNew.status).toBe(403);
    expect(await rNew.json()).toEqual({ error: "diary_closed" });
    const rExisting = await join(stub, "MEMBER01");
    expect(rExisting.status).toBe(200);
  });

  it("refuses an 13th member with 409 diary_full_members (cap is 12)", async () => {
    const stub = stubFor("room-join-3");
    await initDiary(stub, "OWNER001");
    for (let i = 1; i <= 11; i++) expect((await join(stub, `MEMBER${String(i).padStart(2, "0")}`)).status).toBe(201);
    // 12 members now (owner + 11). The 13th distinct account is refused.
    const r = await join(stub, "MEMBER12");
    expect(r.status).toBe(409);
    expect(await r.json()).toEqual({ error: "diary_full_members" });
  });
});

describe("DiaryRoom: leave", () => {
  it("holder in the middle leaves: holderIndex stays pointed at the same person (shifted down)", async () => {
    const stub = stubFor("room-leave-mid");
    await initDiary(stub, "A");
    await join(stub, "B");
    await join(stub, "C"); // members = [A, B, C]
    await postEvent(stub, "A", { type: "pass" }); // holderIndex -> 1 (B)
    const r = await leave(stub, "B");
    const { meta } = await r.json() as { meta: DiaryMeta };
    expect(meta.members).toEqual(["A", "C"]);
    expect(meta.holderIndex).toBe(1); // wraps to C, the next in line
  });

  it("holder at the end leaves: holderIndex wraps to the first member", async () => {
    const stub = stubFor("room-leave-end");
    await initDiary(stub, "A");
    await join(stub, "B");
    await join(stub, "C"); // members = [A, B, C]
    await postEvent(stub, "A", { type: "pass" });
    await postEvent(stub, "B", { type: "pass" }); // holderIndex -> 2 (C)
    const r = await leave(stub, "C");
    const { meta } = await r.json() as { meta: DiaryMeta };
    expect(meta.members).toEqual(["A", "B"]);
    expect(meta.holderIndex).toBe(0); // wrapped
  });

  it("someone before the holder leaves: holderIndex re-indexes to keep pointing at the same holder", async () => {
    const stub = stubFor("room-leave-before");
    await initDiary(stub, "A");
    await join(stub, "B");
    await join(stub, "C"); // members = [A, B, C]
    await postEvent(stub, "A", { type: "pass" });
    await postEvent(stub, "B", { type: "pass" }); // holderIndex -> 2 (C)
    const r = await leave(stub, "A");
    const { meta } = await r.json() as { meta: DiaryMeta };
    expect(meta.members).toEqual(["B", "C"]);
    expect(meta.holderIndex).toBe(1); // still C
  });

  it("owner who is also the current holder leaves: ownership transfers to the new members[0]", async () => {
    const stub = stubFor("room-leave-owner-holder");
    await initDiary(stub, "A");
    await join(stub, "B");
    await join(stub, "C"); // members = [A, B, C], holder = A (owner)
    const r = await leave(stub, "A");
    const { meta } = await r.json() as { meta: DiaryMeta };
    expect(meta.members).toEqual(["B", "C"]);
    expect(meta.ownerAccountId).toBe("B");
    expect(meta.holderIndex).toBe(0); // wrapped from idx 0 % 2
  });

  it("the last member leaving closes the diary without crashing", async () => {
    const stub = stubFor("room-leave-last");
    await initDiary(stub, "SOLO001");
    const r = await leave(stub, "SOLO001");
    expect(r.status).toBe(200);
    const { meta } = await r.json() as { meta: DiaryMeta };
    expect(meta.members).toEqual([]);
    expect(meta.state).toBe("closed");
  });

  it("leave still works once closed, and a non-member leave is an idempotent no-op", async () => {
    const stub = stubFor("room-leave-closed");
    await initDiary(stub, "A");
    await join(stub, "B");
    await close(stub, "A");
    const r = await leave(stub, "B");
    expect(r.status).toBe(200);
    const { meta } = await r.json() as { meta: DiaryMeta };
    expect(meta.members).toEqual(["A"]);
    const rNoop = await leave(stub, "GHOST001");
    expect(rNoop.status).toBe(200);
  });
});

describe("DiaryRoom: close / invite reset", () => {
  it("close is owner-only", async () => {
    const stub = stubFor("room-close-1");
    await initDiary(stub, "A");
    await join(stub, "B");
    expect((await close(stub, "B")).status).toBe(403);
    const r = await close(stub, "A");
    expect(r.status).toBe(200);
    expect(((await r.json()) as { meta: DiaryMeta }).meta.state).toBe("closed");
  });

  it("invite reset is owner-only and invalidates the previous code", async () => {
    const stub = stubFor("room-reset-1");
    const { r: initR } = await initDiary(stub, "A");
    const before = (await initR.json() as DiaryMeta).inviteCode;
    expect((await resetInvite(stub, "NOTOWNER")).status).toBe(403);
    const r = await resetInvite(stub, "A");
    expect(r.status).toBe(200);
    const { inviteCode, previousCode } = await r.json() as { inviteCode: string; previousCode: string };
    expect(previousCode).toBe(before);
    expect(inviteCode).not.toBe(before);
    const meta = await (await getMeta(stub)).json() as DiaryMeta;
    expect(meta.inviteCode).toBe(inviteCode);
  });
});

describe("DiaryRoom: POST /events", () => {
  it("rejects a non-member with 403 not_member", async () => {
    const stub = stubFor("room-ev-member");
    await initDiary(stub, "A");
    const r = await postEvent(stub, "STRANGER", { type: "entry", payloadCipher: fakeCipher() });
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "not_member" });
  });

  it("rejects entry/pass from a non-holder with 403 not_holder; allows comment/like from any member", async () => {
    const stub = stubFor("room-ev-holder");
    await initDiary(stub, "A");
    await join(stub, "B"); // A holds
    expect((await postEvent(stub, "B", { type: "entry", payloadCipher: fakeCipher() })).status).toBe(403);
    expect((await postEvent(stub, "B", { type: "pass" })).status).toBe(403);
    const entrySeq = await postEntry(stub, "A");
    expect((await postEvent(stub, "B", { type: "comment", refSeq: entrySeq, payloadCipher: fakeCipher() })).status).toBe(201);
    expect((await postEvent(stub, "A", { type: "like", refSeq: entrySeq })).status).toBe(201);
  });

  it("a second like by the same person on the same entry returns the existing seq (200), not a duplicate", async () => {
    const stub = stubFor("room-ev-like-dedup");
    await initDiary(stub, "A");
    await join(stub, "B");
    const entrySeq = await postEntry(stub, "A");
    const r1 = await postEvent(stub, "B", { type: "like", refSeq: entrySeq });
    expect(r1.status).toBe(201);
    const { seq: firstSeq } = await r1.json() as { seq: number };
    const r2 = await postEvent(stub, "B", { type: "like", refSeq: entrySeq }); // fresh eventId, same person+entry
    expect(r2.status).toBe(200);
    const { seq: secondSeq } = await r2.json() as { seq: number };
    expect(secondSeq).toBe(firstSeq);
  });

  it("rejects a refSeq pointing at a nonexistent event or a non-entry event with 400 bad_ref", async () => {
    const stub = stubFor("room-ev-badref");
    await initDiary(stub, "A");
    await join(stub, "B");
    const rMissing = await postEvent(stub, "B", { type: "comment", refSeq: 999, payloadCipher: fakeCipher() });
    expect(rMissing.status).toBe(400);
    expect(await rMissing.json()).toEqual({ error: "bad_ref" });
    const entrySeq = await postEntry(stub, "A");
    const commentSeq = (await (await postEvent(stub, "B", { type: "comment", refSeq: entrySeq, payloadCipher: fakeCipher() })).json() as { seq: number }).seq;
    const rNonEntry = await postEvent(stub, "B", { type: "like", refSeq: commentSeq });
    expect(rNonEntry.status).toBe(400);
    expect(await rNonEntry.json()).toEqual({ error: "bad_ref" });
  });

  it("rejects join/leave/meta (and any other unknown type) with 400 bad_type", async () => {
    const stub = stubFor("room-ev-badtype");
    await initDiary(stub, "A");
    for (const type of ["join", "leave", "meta", "bogus"]) {
      const r = await postEvent(stub, "A", { type });
      expect(r.status).toBe(400);
      expect(await r.json()).toEqual({ error: "bad_type" });
    }
  });

  it("rejects an entry with no payload (400 bad_payload) and a like carrying a payload (400 bad_payload)", async () => {
    const stub = stubFor("room-ev-payload");
    await initDiary(stub, "A");
    await join(stub, "B");
    const rNoPayload = await postEvent(stub, "A", { type: "entry" });
    expect(rNoPayload.status).toBe(400);
    expect(await rNoPayload.json()).toEqual({ error: "bad_payload" });
    const entrySeq = await postEntry(stub, "A");
    const rLikeWithPayload = await postEvent(stub, "B", { type: "like", refSeq: entrySeq, payloadCipher: fakeCipher() });
    expect(rLikeWithPayload.status).toBe(400);
    expect(await rLikeWithPayload.json()).toEqual({ error: "bad_payload" });
  });

  it("rejects a decoded payload over 64 KB with 413", async () => {
    const stub = stubFor("room-ev-toolarge");
    await initDiary(stub, "A");
    const r = await postEvent(stub, "A", { type: "entry", payloadCipher: fakeCipher(1, 64 * 1024 + 1) });
    expect(r.status).toBe(413);
    expect(await r.json()).toEqual({ error: "too_large" });
  });

  it("a duplicate eventId returns the same seq (200) and does not advance holderIndex again", async () => {
    const stub = stubFor("room-ev-dup");
    await initDiary(stub, "A");
    await join(stub, "B");
    const eventId = ulid();
    const r1 = await postEvent(stub, "A", { eventId, type: "pass" });
    expect(r1.status).toBe(201);
    const b1 = await r1.json() as { seq: number; holderIndex: number };
    expect(b1.holderIndex).toBe(1);
    const r2 = await postEvent(stub, "A", { eventId, type: "pass" });
    expect(r2.status).toBe(200);
    const b2 = await r2.json() as { seq: number; holderIndex: number };
    expect(b2.seq).toBe(b1.seq);
    expect(b2.holderIndex).toBe(1); // unchanged — did not advance a second time
  });

  it("pass advances holderIndex and wraps around", async () => {
    const stub = stubFor("room-ev-pass-wrap");
    await initDiary(stub, "A");
    await join(stub, "B");
    const r1 = await postEvent(stub, "A", { type: "pass" });
    expect((await r1.json() as { holderIndex: number }).holderIndex).toBe(1);
    const r2 = await postEvent(stub, "B", { type: "pass" });
    expect((await r2.json() as { holderIndex: number }).holderIndex).toBe(0); // wrapped
  });

  it("skip: non-owner 403 not_owner; sole member 403 skip_self; owner-as-holder 403 skip_self; success records `skipped`", async () => {
    const stub = stubFor("room-ev-skip");
    await initDiary(stub, "A"); // owner + sole member, holder = A
    const rSolo = await postEvent(stub, "A", { type: "skip" });
    expect(rSolo.status).toBe(403);
    expect(await rSolo.json()).toEqual({ error: "skip_self" });

    await join(stub, "B"); // members = [A, B], holder still A (owner) -> skip_self
    const rOwnerHolds = await postEvent(stub, "A", { type: "skip" });
    expect(rOwnerHolds.status).toBe(403);
    expect(await rOwnerHolds.json()).toEqual({ error: "skip_self" });

    const rNonOwner = await postEvent(stub, "B", { type: "skip" });
    expect(rNonOwner.status).toBe(403);
    expect(await rNonOwner.json()).toEqual({ error: "not_owner" });

    await postEvent(stub, "A", { type: "pass" }); // holder -> B
    const rOk = await postEvent(stub, "A", { type: "skip" });
    expect(rOk.status).toBe(201);
    const { event, holderIndex } = await rOk.json() as { event: DiaryEvent; holderIndex: number };
    expect(event.skipped).toBe("B");
    expect(holderIndex).toBe(0); // wrapped back to A
  });

  it("accumulates bytesUsed, refuses a new event past the 64 MB cap with 507, and still lets an already-accepted eventId resend through at 200", async () => {
    const stub = stubFor("room-ev-full");
    await initDiary(stub, "A");
    const acceptedSeq = await postEntry(stub, "A", fakeCipher(1, 1000));
    await runInDurableObject(stub, async (_i: DiaryRoom, state) => {
      const meta = await state.storage.get<DiaryMeta>("meta");
      expect(meta).toBeDefined();
      meta!.bytesUsed = 64 * 1024 * 1024 - 100; // just under the cap
      await state.storage.put("meta", meta);
    });
    const rFull = await postEvent(stub, "A", { type: "entry", payloadCipher: fakeCipher(2, 1000) }); // 1000 > remaining 100
    expect(rFull.status).toBe(507);
    expect(await rFull.json()).toEqual({ error: "diary_full" });
    // Resending the eventId of the entry accepted BEFORE the cap was hit is still idempotent-200.
    const meta = await (await getMeta(stub)).json() as DiaryMeta;
    const acceptedEvent = await (await getEvent(stub, acceptedSeq)).json() as DiaryEvent;
    const rReplay = await postEvent(stub, "A", { eventId: acceptedEvent.eventId, type: "entry", payloadCipher: acceptedEvent.payloadCipher });
    expect(rReplay.status).toBe(200);
    void meta;
  });
});

describe("DiaryRoom: GET /events pagination", () => {
  it("`since` excludes that seq, and a full page returns nextSince", async () => {
    const stub = stubFor("room-ev-page");
    await initDiary(stub, "A");
    for (let i = 0; i < 5; i++) await postEvent(stub, "A", { type: "pass" }); // 5 events, seq 1..5 (single member: holderIndex always wraps to 0)
    const p1 = await (await getEvents(stub, "?since=0&limit=2")).json() as { events: DiaryEvent[]; nextSince?: number };
    expect(p1.events.map((e) => e.seq)).toEqual([1, 2]);
    expect(p1.nextSince).toBe(2);
    const p2 = await (await getEvents(stub, `?since=${p1.nextSince}&limit=2`)).json() as { events: DiaryEvent[]; nextSince?: number };
    expect(p2.events.map((e) => e.seq)).toEqual([3, 4]);
    const p3 = await (await getEvents(stub, `?since=${p2.nextSince}&limit=2`)).json() as { events: DiaryEvent[]; nextSince?: number };
    expect(p3.events.map((e) => e.seq)).toEqual([5]);
    expect(p3.nextSince).toBeUndefined();
  });
});

async function postEntry(stub: DurableObjectStub, accountId: string, payloadCipher = fakeCipher()): Promise<number> {
  const r = await postEvent(stub, accountId, { type: "entry", payloadCipher });
  expect(r.status).toBe(201);
  return ((await r.json()) as { seq: number }).seq;
}
