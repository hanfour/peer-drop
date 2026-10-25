// Pure helpers shared by the GroupRoom DO and the /v3/groups routes: id
// formats, byte-length / hashing utilities, and the signed-message formats
// the routes verify against an account's Ed25519 `accounts.signing_key`
// (Ruling 6). Task 8's shared test vectors pin these byte layouts for G1b.

/** 26-char Crockford base32 — the ULID alphabet (no I, L, O, U). */
export const GROUP_ID_RE = /^[0-9A-HJKMNP-TV-Z]{26}$/;

const isId = (s: unknown): s is string => typeof s === "string" && GROUP_ID_RE.test(s);

/** groupId: client-generated ULID naming the GroupRoom DO. */
export const isValidGroupId = isId;
/** memberId: client-generated random id, same alphabet (Ruling 3). */
export const isValidMemberId = isId;
/** eventId: client-generated ULID for idempotent event posts. */
export const isValidEventId = isId;

// Strict standard base64: whole 4-char groups, padding only at the end.
// atob() alone is lenient (accepts whitespace and missing padding), which
// would let two different strings stand for the same bytes.
const B64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

/** Decoded byte length of a strict base64 string, or null if it isn't one. */
export function decodedByteLength(b64: string): number | null {
  if (typeof b64 !== "string" || b64.length % 4 !== 0 || !B64_RE.test(b64)) return null;
  try {
    return atob(b64).length;
  } catch {
    return null;
  }
}

/** Strict base64 → bytes, or null. */
export function decodeB64(b64: string): Uint8Array | null {
  if (decodedByteLength(b64) === null) return null;
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

/**
 * What an account member signs to bind its room public key to this room and
 * seat: utf8("PDGRPMK1") ‖ utf8(groupId) ‖ utf8(memberId) ‖ utf8(accountId)
 * ‖ pubKey. Every field is fixed-length (26 / 26 / 8 / 32), so no separators
 * are needed; the label separates it from every other signed message.
 */
export function memberKeyMessage(groupId: string, memberId: string, accountId: string, pubKey: Uint8Array): Uint8Array {
  return concat([utf8("PDGRPMK1"), utf8(groupId), utf8(memberId), utf8(accountId), pubKey]);
}

/**
 * What the wrapping member signs for one room-key wrap:
 * utf8("PDGRPWK1") ‖ utf8(groupId) ‖ UInt32BE(epoch) ‖ utf8(targetMemberId)
 * ‖ utf8(wrapperMemberId) ‖ wrapped (26 / 4 / 26 / 26 / 92 bytes).
 */
export function wrapMessage(groupId: string, epoch: number, targetMemberId: string, wrapperMemberId: string, wrapped: Uint8Array): Uint8Array {
  const e = new Uint8Array(4);
  new DataView(e.buffer).setUint32(0, epoch >>> 0, false);
  return concat([utf8("PDGRPWK1"), utf8(groupId), e, utf8(targetMemberId), utf8(wrapperMemberId), wrapped]);
}

/**
 * Ed25519-verifies `sigB64` over `message` with the account's registered
 * signing key (`accounts.signing_key`). Any problem — unknown account,
 * malformed signature, D1 error — is simply `false`.
 */
export async function verifyAccountSig(db: D1Database, accountId: string, message: Uint8Array, sigB64: string): Promise<boolean> {
  return verifyAccountSigs(db, accountId, [{ message, sig: sigB64 }]);
}

/**
 * True only when EVERY `sig` verifies over its `message` with the account's
 * signing key (read from D1 once, however many items). Any problem is
 * `false`; an empty list is vacuously true.
 */
export async function verifyAccountSigs(db: D1Database, accountId: string, items: { message: Uint8Array; sig: string }[]): Promise<boolean> {
  try {
    if (items.length === 0) return true;
    const sigs = items.map((i) => decodeB64(i.sig));
    if (sigs.some((s) => !s || s.length !== 64)) return false;
    const row = await db.prepare("SELECT signing_key FROM accounts WHERE account_id = ?1").bind(accountId).first<{ signing_key: ArrayBuffer }>();
    if (!row?.signing_key) return false;
    const raw = new Uint8Array(row.signing_key);
    if (raw.length !== 32) return false;
    const key = await crypto.subtle.importKey("raw", raw, { name: "Ed25519" }, false, ["verify"]);
    const results = await Promise.all(items.map((i, n) => crypto.subtle.verify({ name: "Ed25519" }, key, sigs[n]!, i.message)));
    return results.every(Boolean);
  } catch {
    return false;
  }
}

export async function sha256Hex(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return Array.from(d).map((b) => b.toString(16).padStart(2, "0")).join("");
}
