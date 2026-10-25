// /rotate and /meta both store a `meta` event, so their eventId replay has
// to tell the two apart: an id first used by one endpoint must never make
// the other answer 200 (a /rotate retry would believe the epoch moved), and
// a /meta replay must report the metaVersion that write produced, not the
// room's current one.
import { env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { ulid } from "../notes";
import type { GroupRoom, GroupMeta, Caller } from "../groupRoom";

const stubFor = (name: string) => env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(name));
const b64 = (n: number, fill = 7) => {
  let s = "";
  for (let i = 0; i < n; i++) s += String.fromCharCode(fill);
  return btoa(s);
};
const acct = (memberId: string, accountId: string): Caller => ({ memberId, accountId, deviceId: `DEV-${accountId}`, lane: "bearer" });
const post = (stub: DurableObjectStub, path: string, body: unknown) =>
  stub.fetch(`https://group${path}`, { method: "POST", body: JSON.stringify(body) });

async function initGroup(stub: DurableObjectStub, accountId: string): Promise<Caller> {
  const memberId = ulid();
  const r = await post(stub, "/init", {
    groupId: ulid(),
    owner: { memberId, accountId, pubKey: b64(32), pubKeySig: b64(64) },
    ownerWrap: { wrapped: b64(92), sig: b64(64) },
    metaCipher: "METACIPHERSECRET",
    joinPolicy: "anonymousAllowed",
    inviteCode: "INVITE01",
  });
  expect(r.status).toBe(201);
  return acct(memberId, accountId);
}
const rotate = (stub: DurableObjectStub, caller: Caller, epoch: number, eventId: string, memberIds: string[]) =>
  post(stub, "/rotate", { caller, eventId, epoch, wraps: memberIds.map((memberId) => ({ memberId, wrapped: b64(92, 8), sig: b64(64, 8) })), metaCipher: b64(48, 4) });
const setMeta = (stub: DurableObjectStub, caller: Caller, eventId: string) =>
  post(stub, "/meta", { caller, eventId, metaCipher: b64(32, 6) });
const getMeta = (stub: DurableObjectStub) =>
  runInDurableObject(stub, async (_i: GroupRoom, state) => (await state.storage.get<GroupMeta>("meta"))!);

describe("GroupRoom: rotate / meta replay", () => {
  it("a /meta eventId replayed on /rotate is 409 event_id_taken, not a false 200", async () => {
    const stub = stubFor("gr-replay-meta-then-rotate");
    const owner = await initGroup(stub, "OWNERR01");
    const eventId = ulid();
    expect((await setMeta(stub, owner, eventId)).status).toBe(201);
    const r = await rotate(stub, owner, 2, eventId, [owner.memberId]);
    expect(r.status).toBe(409);
    expect(await r.json()).toEqual({ error: "event_id_taken" });
    expect((await getMeta(stub)).epoch).toBe(1);
  });

  it("a /rotate eventId replayed on /meta is 409 event_id_taken", async () => {
    const stub = stubFor("gr-replay-rotate-then-meta");
    const owner = await initGroup(stub, "OWNERR02");
    const eventId = ulid();
    expect((await rotate(stub, owner, 2, eventId, [owner.memberId])).status).toBe(201);
    const r = await setMeta(stub, owner, eventId);
    expect(r.status).toBe(409);
    expect(await r.json()).toEqual({ error: "event_id_taken" });
    expect((await getMeta(stub)).metaVersion).toBe(2);
  });

  it("/rotate replay still answers 200 with the original seq and epoch", async () => {
    const stub = stubFor("gr-replay-rotate");
    const owner = await initGroup(stub, "OWNERR03");
    const eventId = ulid();
    const first = await rotate(stub, owner, 2, eventId, [owner.memberId]);
    expect(first.status).toBe(201);
    const fb = await first.json() as { seq: number; epoch: number };
    expect((await rotate(stub, owner, 3, ulid(), [owner.memberId])).status).toBe(201);
    const again = await rotate(stub, owner, 2, eventId, [owner.memberId]);
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual(fb);
  });

  it("/meta replay reports the ORIGINAL metaVersion after later updates", async () => {
    const stub = stubFor("gr-replay-meta-version");
    const owner = await initGroup(stub, "OWNERR04");
    const eventId = ulid();
    const first = await setMeta(stub, owner, eventId);
    expect(first.status).toBe(201);
    const fb = await first.json() as { seq: number; metaVersion: number };
    expect(fb.metaVersion).toBe(2);
    expect((await setMeta(stub, owner, ulid())).status).toBe(201);
    expect((await rotate(stub, owner, 2, ulid(), [owner.memberId])).status).toBe(201);
    expect((await getMeta(stub)).metaVersion).toBe(4);
    const again = await setMeta(stub, owner, eventId);
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({ seq: fb.seq, metaVersion: 2 });
  });
});
