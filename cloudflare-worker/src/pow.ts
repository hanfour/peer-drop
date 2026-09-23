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
