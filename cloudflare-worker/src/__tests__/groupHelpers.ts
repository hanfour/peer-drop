// Group HTTP helpers for the /v3/groups* route specs — same raw-fetch shape
// as diaryHelpers.ts (tests read status/json themselves). Unlike notes/diary
// accounts, a group account keeps its Ed25519 signing PRIVATE key, because
// the routes verify member-key and wrap signatures against
// `accounts.signing_key` (Ruling 6).
import { SELF } from "cloudflare:test";
import { expect } from "vitest";
import { registerDevice, deviceToken, b64 } from "./accountHelpers";
import { TEST_MAC_CLIENT_KEY } from "./notesHelpers";
import { ulid } from "../notes";
import { memberKeyMessage, wrapMessage, decodeB64 } from "../groupSig";

export interface GroupAccount { accountId: string; token: string; deviceId: string; signKey: CryptoKey }
export interface AnonDevice { deviceId: string; token: string }

/** Register a device → account, keeping the signing private key. */
export async function makeGroupAccount(deviceId: string): Promise<GroupAccount> {
  const r = await registerDevice(deviceId);
  expect(r.reg.status).toBe(201);
  const { accountId, token } = await r.reg.json() as { accountId: string; token: string };
  return { accountId, token, deviceId, signKey: r.pair.kp.privateKey };
}

/** A device with a default-scope (not signed in) Bearer token. */
export async function makeAnonDevice(deviceId: string): Promise<AnonDevice> {
  return { deviceId, token: await deviceToken(deviceId) };
}

export const newMemberId = (): string => ulid();
export const newGroupId = (): string => ulid();

function randomB64(n: number): string {
  return b64(crypto.getRandomValues(new Uint8Array(n)));
}
/** A 32-byte (fake) X25519 public key. */
export const fakePubKey = (): string => randomB64(32);
/** A 92-byte (fake) wrapped room key. */
export const fakeWrap = (): string => randomB64(92);
/** A base64 blob of `byteLen` bytes standing in for metaCipher. */
export function fakeMeta(byteLen = 48): string {
  const bytes = new Uint8Array(byteLen).fill(5);
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

async function sign(key: CryptoKey, msg: Uint8Array): Promise<string> {
  return b64(new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, key, msg)));
}
export function signMemberKey(a: GroupAccount, groupId: string, memberId: string, pubKey: string): Promise<string> {
  return sign(a.signKey, memberKeyMessage(groupId, memberId, a.accountId, decodeB64(pubKey)!));
}
export function signWrap(a: GroupAccount, groupId: string, epoch: number, target: string, wrapper: string, wrapped: string): Promise<string> {
  return sign(a.signKey, wrapMessage(groupId, epoch, target, wrapper, decodeB64(wrapped)!));
}

export const bearer = (a: { token: string }): Record<string, string> => ({ Authorization: `Bearer ${a.token}`, "Content-Type": "application/json" });
export const keyLane = (a: { deviceId: string }): Record<string, string> => ({ "X-API-Key": TEST_MAC_CLIENT_KEY, "X-Device-Id": a.deviceId, "Content-Type": "application/json" });
/** Headers plus the X-Group-Member-Id a member request carries. */
export const asMember = (h: Record<string, string>, memberId: string): Record<string, string> => ({ ...h, "X-Group-Member-Id": memberId });

export interface CreateBody { groupId: string; memberId: string; pubKey: string; pubKeySig: string; ownerWrap: { wrapped: string; sig: string }; metaCipher: string; joinPolicy?: string }

/** A correctly signed create body for `owner`. */
export async function createBody(owner: GroupAccount, opts: { groupId?: string; joinPolicy?: string; metaCipher?: string } = {}): Promise<CreateBody> {
  const groupId = opts.groupId ?? newGroupId();
  const memberId = newMemberId();
  const pubKey = fakePubKey();
  const wrapped = fakeWrap();
  const body: CreateBody = {
    groupId, memberId, pubKey,
    pubKeySig: await signMemberKey(owner, groupId, memberId, pubKey),
    ownerWrap: { wrapped, sig: await signWrap(owner, groupId, 1, memberId, memberId, wrapped) },
    metaCipher: opts.metaCipher ?? fakeMeta(),
  };
  if (opts.joinPolicy) body.joinPolicy = opts.joinPolicy;
  return body;
}

export function createGroup(headers: Record<string, string>, body: unknown): Promise<Response> {
  return SELF.fetch("https://example.com/v3/groups", { method: "POST", headers, body: typeof body === "string" ? body : JSON.stringify(body) });
}

/** Create + assert 201. */
export async function createGroupOk(owner: GroupAccount, opts: { joinPolicy?: string; groupId?: string } = {}): Promise<{ groupId: string; inviteCode: string; memberId: string }> {
  const body = await createBody(owner, opts);
  const r = await createGroup(bearer(owner), body);
  if (r.status !== 201) throw new Error(`createGroupOk: expected 201, got ${r.status}: ${await r.text()}`);
  const { inviteCode } = await r.json() as { inviteCode: string };
  return { groupId: body.groupId, inviteCode, memberId: body.memberId };
}

export interface JoinBody { inviteCode?: string; memberId?: string; pubKey?: string; pubKeySig?: string; as?: string }

export function joinGroup(headers: Record<string, string>, groupId: string | null, body: JoinBody | string): Promise<Response> {
  const url = groupId ? `https://example.com/v3/groups/${groupId}/join` : "https://example.com/v3/groups/join";
  return SELF.fetch(url, { method: "POST", headers, body: typeof body === "string" ? body : JSON.stringify(body) });
}

/** A correctly signed account join body. */
export async function accountJoinBody(a: GroupAccount, groupId: string, inviteCode: string): Promise<JoinBody & { memberId: string }> {
  const memberId = newMemberId();
  const pubKey = fakePubKey();
  return { inviteCode, memberId, pubKey, pubKeySig: await signMemberKey(a, groupId, memberId, pubKey), as: "account" };
}
export function anonJoinBody(inviteCode: string): JoinBody & { memberId: string } {
  return { inviteCode, memberId: newMemberId(), pubKey: fakePubKey(), as: "anon" };
}

/** Account join + assert 201, returning the new memberId. */
export async function joinAsAccountOk(a: GroupAccount, groupId: string, inviteCode: string): Promise<string> {
  const body = await accountJoinBody(a, groupId, inviteCode);
  const r = await joinGroup(bearer(a), groupId, body);
  if (r.status !== 201) throw new Error(`joinAsAccountOk: expected 201, got ${r.status}: ${await r.text()}`);
  return body.memberId;
}

export function listGroups(headers: Record<string, string>): Promise<Response> {
  return SELF.fetch("https://example.com/v3/groups", { headers });
}
export function getGroup(headers: Record<string, string>, groupId: string): Promise<Response> {
  return SELF.fetch(`https://example.com/v3/groups/${groupId}`, { headers });
}
const postTo = (headers: Record<string, string>, path: string, body?: unknown) =>
  SELF.fetch(`https://example.com${path}`, { method: "POST", headers, body: body === undefined ? undefined : JSON.stringify(body) });
export const leaveGroup = (h: Record<string, string>, groupId: string) => postTo(h, `/v3/groups/${groupId}/leave`);
export const kickMember = (h: Record<string, string>, groupId: string, memberId: string) => postTo(h, `/v3/groups/${groupId}/kick`, { memberId });
export const closeGroup = (h: Record<string, string>, groupId: string) => postTo(h, `/v3/groups/${groupId}/close`);
export const resetGroupInvite = (h: Record<string, string>, groupId: string) => postTo(h, `/v3/groups/${groupId}/invite/reset`);
