// Passing-notes server side: pure helpers (this file's top half) and the
// /v3 notes routes (bottom half, added in later tasks). Everything here is
// ciphertext-only — the worker never sees a note's plaintext.
import type { Env } from "./index";

export const NOTE_LIMITS = {
  envelopeMaxBytes: 16 * 1024,
  perSenderPerDay: 200,
  perRecipientPerDay: 500,
  reportsPerDay: 20,
  powChallengesPerMinute: 60,
  powChallengeTtlSeconds: 300,
  powDifficulty: 16,
  inboxCap: 1000,
  retentionMs: 90 * 86_400_000,
  excerptMaxChars: 1000,
} as const;

// Crockford base32 (ULID spec): 10 time chars (ms since epoch) + 16 random.
const ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export function ulid(now: number = Date.now()): string {
  let t = now;
  let time = "";
  for (let i = 0; i < 10; i++) { time = ULID_ALPHABET[t % 32] + time; t = Math.floor(t / 32); }
  const rnd = new Uint8Array(16);
  crypto.getRandomValues(rnd);
  let rand = "";
  for (let i = 0; i < 16; i++) rand += ULID_ALPHABET[rnd[i] % 32]; // 256 % 32 === 0 → unbiased
  return time + rand;
}

const hex = (u8: Uint8Array) => Array.from(u8).map((b) => b.toString(16).padStart(2, "0")).join("");

/** Irreversible sender identifier: HMAC keyed by the server-only TOKEN_SECRET. */
export async function senderHash(secret: string, accountId: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode("note-sender:" + accountId))));
}

/** The exact string both sides feed to the hashcash: challenge|recipient|sha256hex(envelope). */
export async function notePoWMessage(challenge: string, recipientAccountId: string, envelopeBytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", envelopeBytes));
  return `${challenge}|${recipientAccountId}|${hex(digest)}`;
}

export type ParsedEnvelope = { ok: true; bytes: Uint8Array } | { ok: false; error: "invalid_envelope" | "too_large" };

/** Shape-check the base64 NoteEnvelope JSON without interpreting it. */
export function parseEnvelope(b64: string): ParsedEnvelope {
  if (typeof b64 !== "string" || b64.length > Math.ceil((NOTE_LIMITS.envelopeMaxBytes * 4) / 3) + 4) return { ok: false, error: "too_large" };
  let bytes: Uint8Array;
  try { bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)); } catch { return { ok: false, error: "invalid_envelope" }; }
  if (bytes.length > NOTE_LIMITS.envelopeMaxBytes) return { ok: false, error: "too_large" };
  let obj: Record<string, unknown>;
  try { obj = JSON.parse(new TextDecoder().decode(bytes)); } catch { return { ok: false, error: "invalid_envelope" }; }
  if (!obj || typeof obj !== "object" || obj.v !== 1) return { ok: false, error: "invalid_envelope" };
  const lenOf = (v: unknown): number => { if (typeof v !== "string") return -1; try { return atob(v).length; } catch { return -1; } };
  if (lenOf(obj.ephemeralKey) !== 32 || lenOf(obj.ephemeralKey2) !== 32 || lenOf(obj.nonce) !== 12 || lenOf(obj.ciphertext) < 16) return { ok: false, error: "invalid_envelope" };
  if (!Number.isInteger(obj.spkId)) return { ok: false, error: "invalid_envelope" };
  if (obj.opkId !== undefined && obj.opkId !== null && !Number.isInteger(obj.opkId)) return { ok: false, error: "invalid_envelope" };
  return { ok: true, bytes };
}

// Referenced by later tasks' route code; keeps the type import "used" for tsc.
export type NotesEnv = Env;
