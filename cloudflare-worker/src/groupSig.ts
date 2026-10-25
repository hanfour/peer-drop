// Pure helpers shared by the GroupRoom DO and the /v3/groups routes: id
// formats and byte-length / hashing utilities. (Signature-message assembly
// and Ed25519 verification land here too, in a later task.)

/** 26-char Crockford base32 — the ULID alphabet (no I, L, O, U). */
export const GROUP_ID_RE = /^[0-9A-HJKMNP-TV-Z]{26}$/;

const isId = (s: unknown): s is string => typeof s === "string" && GROUP_ID_RE.test(s);

/** groupId: client-generated ULID naming the GroupRoom DO. */
export const isValidGroupId = isId;
/** memberId: client-generated random id, same alphabet (Ruling 3). */
export const isValidMemberId = isId;
/** eventId: client-generated ULID for idempotent event posts. */
export const isValidEventId = isId;

/** atob() length of a base64 string, or null if it isn't valid base64. */
export function decodedByteLength(b64: string): number | null {
  try {
    return atob(b64).length;
  } catch {
    return null;
  }
}

export async function sha256Hex(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return Array.from(d).map((b) => b.toString(16).padStart(2, "0")).join("");
}
