// Rendezvous claim validation + proof-of-work (Project E).
//
// Single source of truth for the rule; the Swift client mirrors it using
// test-vectors/rendezvous-pow.json:
//   PoW = SHA256(tokenBytes(32) || UInt64BE(hour) || utf8(nonce))
//   must have >= 16 leading zero BITS, and
//   hour in { floor(now/3600), floor(now/3600) - 1 } (UTC hour index).

export const RV_POW_DIFFICULTY_BITS = 16;
export const RV_MAX_FRAME_BYTES = 512;
export const RV_MAX_NONCE_CHARS = 64;
const TOKEN_BYTES = 32;

export function decodeBase64UrlStrict(s: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]+$/.test(s)) return null;
  if (s.length % 4 === 1) return null;
  try {
    const padded = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
    const bin = atob(padded);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function leadingZeroBits(hash: Uint8Array): number {
  let zeros = 0;
  for (const byte of hash) {
    if (byte === 0) { zeros += 8; continue; }
    zeros += Math.clz32(byte) - 24;
    break;
  }
  return zeros;
}

export async function rendezvousPowBits(tokenBytes: Uint8Array, hour: number, nonce: string): Promise<number> {
  const n = new TextEncoder().encode(nonce);
  const buf = new Uint8Array(tokenBytes.length + 8 + n.length);
  buf.set(tokenBytes, 0);
  new DataView(buf.buffer).setBigUint64(tokenBytes.length, BigInt(hour), false);
  buf.set(n, tokenBytes.length + 8);
  return leadingZeroBits(new Uint8Array(await crypto.subtle.digest("SHA-256", buf)));
}

/**
 * Validate a parsed claim `{v:1, t, pow:{h, n}}`. Returns the canonical token
 * string on success, null on ANY failure (callers must not distinguish).
 */
export async function verifyRendezvousClaim(claim: unknown, nowMs: number): Promise<string | null> {
  if (typeof claim !== "object" || claim === null) return null;
  const c = claim as { v?: unknown; t?: unknown; pow?: unknown };
  if (c.v !== 1 || typeof c.t !== "string") return null;
  const pow = c.pow as { h?: unknown; n?: unknown } | null;
  if (typeof pow !== "object" || pow === null) return null;
  const { h, n } = pow;
  if (typeof h !== "number" || !Number.isSafeInteger(h) || h < 0) return null;
  if (typeof n !== "string" || n.length === 0 || n.length > RV_MAX_NONCE_CHARS) return null;
  const tokenBytes = decodeBase64UrlStrict(c.t);
  if (!tokenBytes || tokenBytes.length !== TOKEN_BYTES) return null;
  // Canonical form only (no non-zero trailing bits) so one room has one name.
  const canonical = c.t;
  const current = Math.floor(nowMs / 3_600_000);
  if (h !== current && h !== current - 1) return null;
  if ((await rendezvousPowBits(tokenBytes, h, n)) < RV_POW_DIFFICULTY_BITS) return null;
  return canonical;
}
