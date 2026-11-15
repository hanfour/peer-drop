// Proof-of-Work verification (matches the client-side SHA256 hashcash in
// PeerDropSecurity/ProofOfWork.swift): SHA256(utf8(challenge) || nonce as
// 8-byte big-endian) must start with `difficulty` zero bits. Shared by
// /v2/messages and the /v3/notes route.
export async function verifyPoW(challenge: string, proof: number, difficulty: number): Promise<boolean> {
  const data = new TextEncoder().encode(challenge);
  const proofBytes = new ArrayBuffer(8);
  new DataView(proofBytes).setBigUint64(0, BigInt(proof), false); // big-endian
  const combined = new Uint8Array(data.length + 8);
  combined.set(data, 0);
  combined.set(new Uint8Array(proofBytes), data.length);
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", combined));
  let zeroBits = 0;
  for (const byte of hash) {
    if (byte === 0) {
      zeroBits += 8;
    } else {
      zeroBits += Math.clz32(byte) - 24;
      break;
    }
    if (zeroBits >= difficulty) return true;
  }
  return zeroBits >= difficulty;
}

/** Leading zero bits of a SHA-256 digest. */
export function countLeadingZeroBits(hash: Uint8Array): number {
  let bits = 0;
  for (const byte of hash) {
    if (byte === 0) { bits += 8; continue; }
    bits += Math.clz32(byte) - 24;
    break;
  }
  return bits;
}

/** Operator-tunable difficulty for the bound mailbox PoW; a bad value falls back to 16. */
export function boundPoWDifficulty(raw: string | undefined): number {
  const n = parseInt(raw ?? "", 10);
  return Number.isFinite(n) && n > 0 && n <= 32 ? n : 16;
}

/**
 * Mailbox PoW bound to what is being sent:
 *   sha256( utf8(challenge) || utf8(mailboxId) || sha256(utf8(ciphertext)) || proof as 8-byte big-endian )
 * must start with `difficulty` zero bits. A proof therefore cannot be reused for another mailbox or
 * another ciphertext, and the challenge is issued by the server and redeemed once.
 */
export async function verifyBoundPoW(
  challenge: string, mailboxId: string, ciphertext: string, proof: number, difficulty: number,
): Promise<boolean> {
  if (!Number.isSafeInteger(proof) || proof < 0) return false;
  const enc = new TextEncoder();
  const ctHash = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(ciphertext)));
  const challengeBytes = enc.encode(challenge);
  const mailboxBytes = enc.encode(mailboxId);
  const combined = new Uint8Array(challengeBytes.length + mailboxBytes.length + ctHash.length + 8);
  let offset = 0;
  combined.set(challengeBytes, offset); offset += challengeBytes.length;
  combined.set(mailboxBytes, offset); offset += mailboxBytes.length;
  combined.set(ctHash, offset); offset += ctHash.length;
  new DataView(combined.buffer, offset, 8).setBigUint64(0, BigInt(proof), false);
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", combined));
  return countLeadingZeroBits(hash) >= difficulty;
}
