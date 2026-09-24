import { SELF, env } from "cloudflare:test";
import { expect } from "vitest";
import { registerDevice } from "./accountHelpers";
import { notePoWMessage } from "../notes";
import { verifyPoW } from "../pow";
import { normalizeAccountId } from "../account";

export const TEST_MAC_CLIENT_KEY = "test-mac-client-key-67890";

export interface TestAccount { accountId: string; token: string; deviceId: string; mailboxId: string }

/** Register a device → account and return what the notes routes need. */
export async function makeAccount(deviceId: string, platform = "ios"): Promise<TestAccount> {
  const r = await registerDevice(deviceId, platform);
  expect(r.reg.status).toBe(201);
  const { accountId, token } = await r.reg.json() as { accountId: string; token: string };
  return { accountId, token, deviceId, mailboxId: r.mailboxId };
}

export const bearer = (a: TestAccount) => ({ Authorization: `Bearer ${a.token}`, "Content-Type": "application/json" });
export const keyLane = (a: TestAccount) => ({ "X-API-Key": TEST_MAC_CLIENT_KEY, "X-Device-Id": a.deviceId, "Content-Type": "application/json" });

const b64 = (n: number, fill: number) => btoa(String.fromCharCode(...new Uint8Array(n).fill(fill)));
/** A shape-valid (but cryptographically meaningless) base64 envelope. */
export function fakeEnvelope(seed = 1, ciphertextLen = 64): string {
  return btoa(JSON.stringify({ v: 1, ephemeralKey: b64(32, seed), ephemeralKey2: b64(32, seed + 1), spkId: 1, opkId: 5, nonce: b64(12, seed), ciphertext: b64(ciphertextLen, seed) }));
}

export async function getChallenge(headers: Record<string, string>): Promise<string> {
  const r = await SELF.fetch("https://example.com/v3/pow/challenge", { headers });
  expect(r.status).toBe(200);
  return (await r.json() as { challenge: string }).challenge;
}

/**
 * Brute-force the 16-bit hashcash the way the client does (≈1 s). The
 * server hashes the NORMALIZED (canonical 8-char) recipient id — not
 * whatever handle string the caller typed into the URL — so normalize here
 * too; falls back to the raw string if it doesn't normalize (matching the
 * server's own "not a real handle" rejection path, which never reaches PoW
 * verification anyway).
 */
export async function solvePoW(challenge: string, recipientAccountId: string, envelopeB64: string): Promise<number> {
  const bytes = Uint8Array.from(atob(envelopeB64), (c) => c.charCodeAt(0));
  const canonical = normalizeAccountId(recipientAccountId) ?? recipientAccountId;
  const msg = await notePoWMessage(challenge, canonical, bytes);
  let nonce = 0;
  while (!(await verifyPoW(msg, nonce, 16))) nonce++;
  return nonce;
}

/**
 * Full send flow: challenge → PoW → POST. Returns the raw Response.
 * `extra` merges into the JSON body alongside `envelope`/`pow` — used by
 * the diaryKey relay tests to add `{kind: "diaryKey", diaryId}` without
 * every other (note) caller having to know about those fields.
 */
export async function sendNote(headers: Record<string, string>, recipientAccountId: string, envelope = fakeEnvelope(), extra: Record<string, unknown> = {}): Promise<Response> {
  const challenge = await getChallenge(headers);
  const nonce = await solvePoW(challenge, recipientAccountId, envelope);
  return SELF.fetch(`https://example.com/v3/notes/${recipientAccountId}`, { method: "POST", headers, body: JSON.stringify({ envelope, pow: { challenge, nonce }, ...extra }) });
}

export async function inboxOf(a: TestAccount): Promise<{ items: { id: string; envelope: string; readAt: number | null }[]; nextAfter?: string }> {
  const stub = env.ACCOUNT_INBOX.get(env.ACCOUNT_INBOX.idFromName(a.accountId));
  return (await stub.fetch("https://inbox/items")).json();
}
