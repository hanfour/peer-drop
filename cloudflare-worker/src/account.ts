/** Account layer helpers shared by /v2 token issuance and /v3 routes. */
//
// Device-token issuance must never fail closed on the accounts DB: both
// call sites (in /v2/device/attest and /v2/device/assert) sit inside those
// handlers' outer try/catch → 400, so an unhandled D1 error here would turn
// into a 400 for EVERY attest/assert call — locking every shipped device
// out of relay features on a D1 outage, an unbound binding, or a migration
// that hasn't landed yet at deploy time. Fail open to the "default" scope
// instead; a device that should have been account-scoped just behaves like
// an unbound one until the next successful lookup.
export async function scopeForDevice(db: D1Database, deviceId: string): Promise<string> {
  try {
    const row = await db.prepare("SELECT account_id FROM account_devices WHERE device_id = ?1")
      .bind(deviceId).first<{ account_id: string }>();
    return row ? `account:${row.account_id}` : "default";
  } catch (err) {
    console.error("scopeForDevice: falling back to default scope", String(err));
    return "default";
  }
}

export function accountIdFromScope(scope: string): string | null {
  return scope.startsWith("account:") && scope.length > 8 ? scope.slice(8) : null;
}

// =====================================================================
// Account ID + nickname helpers (T4: /v3/account/* routes)
// =====================================================================

// Crockford-ish base32, minus I/L/O/U (kept out so normalizeAccountId's
// confusable mapping — I/L→1, O→0 — never produces a character that
// itself needs remapping, and U is dropped to avoid spelling accidental
// profanity in random ids).
export const ACCOUNT_ID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export const RESERVED_NICKNAMES = ["admin", "peerdrop", "support", "system", "null", "me"];

/** 8 chars from 40 random bits, drawn from ACCOUNT_ID_ALPHABET (32 symbols = 5 bits/char). */
export function generateAccountId(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  let out = "";
  for (let i = 0; i < 8; i++) out += ACCOUNT_ID_ALPHABET[bytes[i] % 32];
  return out;
}

/**
 * Normalize a user-typed account id: strip separators/whitespace, uppercase,
 * then map the confusable letters I/L→1 and O→0 (matches how the id is
 * rendered — see ACCOUNT_ID_ALPHABET). Returns null if the result isn't
 * exactly 8 chars, all drawn from the alphabet.
 */
export function normalizeAccountId(input: string): string | null {
  const cleaned = input.replace(/[\s-]/g, "").toUpperCase().replace(/[IL]/g, "1").replace(/O/g, "0");
  if (cleaned.length !== 8) return null;
  for (const c of cleaned) if (!ACCOUNT_ID_ALPHABET.includes(c)) return null;
  return cleaned;
}

export type NicknameCheck = { ok: true; value: string } | { ok: false; code: "invalid_nickname" | "reserved" };

/** NFC-normalize, then require 3-20 Unicode scalars of \p{L}\p{N}_ and reject reserved words. */
export function validateNickname(raw: string): NicknameCheck {
  const value = raw.normalize("NFC");
  const scalars = Array.from(value);
  if (scalars.length < 3 || scalars.length > 20) return { ok: false, code: "invalid_nickname" };
  if (!/^[\p{L}\p{N}_]+$/u.test(value)) return { ok: false, code: "invalid_nickname" };
  if (RESERVED_NICKNAMES.includes(value.toLowerCase())) return { ok: false, code: "reserved" };
  return { ok: true, value };
}

/**
 * Verify an Ed25519 registration signature over
 * utf8("peerdrop-account-v1") ‖ nonce(32) ‖ utf8(deviceId), proving the
 * caller controls the private key matching `signingKeyRaw` (the account's
 * durable identity — separate from the device's App Attest keypair).
 */
export async function verifyRegistrationSignature(
  signingKeyRaw: Uint8Array,
  nonce: Uint8Array,
  deviceId: string,
  signature: Uint8Array,
): Promise<boolean> {
  if (signingKeyRaw.length !== 32 || nonce.length !== 32 || signature.length !== 64) return false;
  try {
    const key = await crypto.subtle.importKey("raw", signingKeyRaw, { name: "Ed25519" }, false, ["verify"]);
    const enc = new TextEncoder();
    const msg = new Uint8Array([...enc.encode("peerdrop-account-v1"), ...nonce, ...enc.encode(deviceId)]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, signature, msg);
  } catch {
    return false;
  }
}

/**
 * Classify a D1 write error from the atomic register batch (see
 * `/v3/account/register` in index.ts) by which UNIQUE constraint it
 * tripped, so the route can turn each into the right outcome — retry with
 * a fresh id, a specific 409, or "someone else just won a race, proceed
 * down the existing-account path" — instead of one generic 500. D1/SQLite
 * error messages take the form
 * `D1_ERROR: UNIQUE constraint failed: <table>.<column>: SQLITE_CONSTRAINT...`;
 * matching is done by substring rather than a strict parse so message
 * formatting drift across D1/workerd versions doesn't silently stop
 * classifying (worst case: falls through to "other", which the caller
 * rethrows — a clear failure rather than a silently wrong outcome).
 */
export function classifyRegisterError(
  err: unknown,
): "account_id" | "identity_bound" | "signing_key" | "device_bound" | "other" {
  const msg = String((err as { message?: unknown })?.message ?? err);
  if (msg.includes("accounts.identity_key")) return "identity_bound";
  if (msg.includes("accounts.account_id")) return "account_id";
  if (msg.includes("accounts.signing_key")) return "signing_key";
  if (msg.includes("account_devices")) return "device_bound";
  return "other";
}

export interface AccountRow {
  account_id: string;
  signing_key: ArrayBuffer;
  identity_key: ArrayBuffer;
  nickname: string | null;
  mailbox_id: string;
}

/**
 * Resolve a user-typed handle to an account row — tried as a normalized
 * account id first, then as a nickname (case-insensitive, matching the
 * `accounts.nickname` COLLATE NOCASE column). Used by T5's lookup route.
 */
export async function findAccountByHandle(db: D1Database, handle: string): Promise<AccountRow | null> {
  const id = normalizeAccountId(handle);
  if (id) {
    const byId = await db.prepare("SELECT * FROM accounts WHERE account_id = ?1").bind(id).first<AccountRow>();
    if (byId) return byId;
  }
  const nick = validateNickname(handle);
  if (!nick.ok) return null;
  return await db.prepare("SELECT * FROM accounts WHERE nickname = ?1 COLLATE NOCASE").bind(nick.value).first<AccountRow>();
}
