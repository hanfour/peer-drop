// Diary HTTP helpers, layered on notesHelpers' makeAccount/bearer/keyLane —
// same shape as notesHelpers.ts (raw fetch wrappers; tests read status/json
// themselves rather than every helper asserting success, since most of the
// diary acceptance criteria are about the non-2xx paths).
import { SELF } from "cloudflare:test";
import { bearer } from "./notesHelpers";
import type { TestAccount } from "./notesHelpers";
import { ulid } from "../notes";

export { makeAccount, bearer, keyLane, TEST_MAC_CLIENT_KEY } from "./notesHelpers";
export type { TestAccount } from "./notesHelpers";

let ciphSeed = 0;

export function newDiaryId(): string {
  return ulid();
}

/**
 * A base64 blob that isn't cryptographically real — the worker never
 * inspects it. Unique per call by default so tests don't accidentally
 * share dedup-sensitive state. Encodes in 32 KB chunks rather than
 * `String.fromCharCode(...bytes)` in one call, which blows the call stack
 * once `byteLen` gets into the tens of thousands (spreading a huge typed
 * array into function arguments) — needed here since size-limit tests push
 * `byteLen` past 64 KB.
 */
export function fakeCipher(seed = ++ciphSeed, byteLen = 32): string {
  const bytes = new Uint8Array(byteLen).fill(seed % 256);
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(binary);
}

export async function createDiary(headers: Record<string, string>, diaryId = newDiaryId(), metaCipher = fakeCipher()): Promise<Response> {
  return SELF.fetch("https://example.com/v3/diaries", { method: "POST", headers, body: JSON.stringify({ diaryId, metaCipher }) });
}

/** Create + assert 201, returning the parsed body plus the diaryId/metaCipher used. */
export async function createDiaryOk(a: TestAccount): Promise<{ diaryId: string; inviteCode: string; metaCipher: string }> {
  const diaryId = newDiaryId();
  const metaCipher = fakeCipher();
  const r = await createDiary(bearer(a), diaryId, metaCipher);
  if (r.status !== 201) throw new Error(`createDiaryOk: expected 201, got ${r.status}: ${await r.text()}`);
  const { inviteCode } = await r.json() as { diaryId: string; inviteCode: string };
  return { diaryId, inviteCode, metaCipher };
}

export async function listDiaries(headers: Record<string, string>): Promise<Response> {
  return SELF.fetch("https://example.com/v3/diaries", { headers });
}

export async function getDiary(headers: Record<string, string>, diaryId: string): Promise<Response> {
  return SELF.fetch(`https://example.com/v3/diaries/${diaryId}`, { headers });
}

export async function joinByLink(headers: Record<string, string>, diaryId: string, inviteCode: string): Promise<Response> {
  return SELF.fetch(`https://example.com/v3/diaries/${diaryId}/join`, { method: "POST", headers, body: JSON.stringify({ inviteCode }) });
}

export async function joinByCode(headers: Record<string, string>, inviteCode: string): Promise<Response> {
  return SELF.fetch("https://example.com/v3/diaries/join", { method: "POST", headers, body: JSON.stringify({ inviteCode }) });
}

export async function leaveDiary(headers: Record<string, string>, diaryId: string): Promise<Response> {
  return SELF.fetch(`https://example.com/v3/diaries/${diaryId}/leave`, { method: "POST", headers });
}

export async function closeDiary(headers: Record<string, string>, diaryId: string): Promise<Response> {
  return SELF.fetch(`https://example.com/v3/diaries/${diaryId}/close`, { method: "POST", headers });
}

export async function resetInvite(headers: Record<string, string>, diaryId: string): Promise<Response> {
  return SELF.fetch(`https://example.com/v3/diaries/${diaryId}/invite/reset`, { method: "POST", headers });
}

export async function getEvents(headers: Record<string, string>, diaryId: string, query = ""): Promise<Response> {
  return SELF.fetch(`https://example.com/v3/diaries/${diaryId}/events${query}`, { headers });
}

export interface PostEventBody { eventId?: string; type: string; refSeq?: number; payloadCipher?: string }
export async function postEvent(headers: Record<string, string>, diaryId: string, body: PostEventBody): Promise<Response> {
  const full = { eventId: body.eventId ?? ulid(), ...body };
  return SELF.fetch(`https://example.com/v3/diaries/${diaryId}/events`, { method: "POST", headers, body: JSON.stringify(full) });
}

export async function requestKey(headers: Record<string, string>, diaryId: string): Promise<Response> {
  return SELF.fetch(`https://example.com/v3/diaries/${diaryId}/request-key`, { method: "POST", headers });
}

export async function reportEvent(headers: Record<string, string>, diaryId: string, seq: number, body: { reason: string; excerpt?: string }): Promise<Response> {
  return SELF.fetch(`https://example.com/v3/diaries/${diaryId}/events/${seq}/report`, { method: "POST", headers, body: JSON.stringify(body) });
}

/** Post an `entry` event as the current holder and return its seq. */
export async function postEntryOk(headers: Record<string, string>, diaryId: string, text = fakeCipher(2)): Promise<number> {
  const r = await postEvent(headers, diaryId, { type: "entry", payloadCipher: text });
  if (![200, 201].includes(r.status)) throw new Error(`postEntryOk: expected 200/201, got ${r.status}: ${await r.text()}`);
  const { seq } = await r.json() as { seq: number };
  return seq;
}
