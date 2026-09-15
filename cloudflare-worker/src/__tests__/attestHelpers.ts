// Shared helpers for synthesizing Apple App Attest *assertions* in tests,
// without needing a real iOS device or Secure Enclave. Extracted from
// device-token.spec.ts (which pinned the assertion math end-to-end
// against `verifyAssertion` directly) so appAttestBundles.spec.ts can
// reuse the exact same CBOR/DER plumbing to build route-level requests
// against `/v2/device/assert` instead of duplicating it.

import { encode as cborEncode } from "cbor2";

/// rpIdHash = SHA-256(`${teamId}.${bundleId}`) — same formula the worker
/// uses in appAttest.ts's `matchRpIdHash`.
export async function rpIdHashFor(teamId: string, bundleId: string): Promise<Uint8Array> {
  return new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${teamId}.${bundleId}`)),
  );
}

/// Assertion-shaped authData: rpIdHash (32) + flags (1, always 0 here) +
/// counter (4, big-endian) = 37 bytes.
export function buildAuthData(rpHash: Uint8Array, counter: number): Uint8Array {
  const buf = new Uint8Array(37);
  buf.set(rpHash, 0);
  buf[32] = 0;
  buf[33] = (counter >>> 24) & 0xff;
  buf[34] = (counter >>> 16) & 0xff;
  buf[35] = (counter >>> 8) & 0xff;
  buf[36] = counter & 0xff;
  return buf;
}

/// Web Crypto returns ECDSA signatures in IEEE 1363 raw r||s (64 bytes for
/// P-256). Apple/CBOR carries DER. Convert.
export function rawSigToDer(rawSig: Uint8Array): Uint8Array {
  const r = rawSig.subarray(0, 32);
  const s = rawSig.subarray(32, 64);
  const encInt = (n: Uint8Array): Uint8Array => {
    // Strip leading zeros, then re-add ONE if the high bit is set (DER
    // INTEGERs are signed, so a high-bit byte needs the 0x00 prefix to
    // stay positive).
    let i = 0;
    while (i < n.length - 1 && n[i] === 0) i++;
    let stripped = n.subarray(i);
    if (stripped[0] & 0x80) {
      const padded = new Uint8Array(stripped.length + 1);
      padded.set(stripped, 1);
      stripped = padded;
    }
    const tlv = new Uint8Array(2 + stripped.length);
    tlv[0] = 0x02; tlv[1] = stripped.length; tlv.set(stripped, 2);
    return tlv;
  };
  const rTLV = encInt(r);
  const sTLV = encInt(s);
  const out = new Uint8Array(2 + rTLV.length + sTLV.length);
  out[0] = 0x30; out[1] = rTLV.length + sTLV.length;
  out.set(rTLV, 2);
  out.set(sTLV, 2 + rTLV.length);
  return out;
}

/// Sign SHA-256(authData || SHA-256(clientData)) with the given private
/// key and return the DER-encoded signature, matching what a real
/// DCAppAttestService assertion carries.
export async function signAssertion(privateKey: CryptoKey, authData: Uint8Array, clientData: Uint8Array): Promise<Uint8Array> {
  const clientDataHash = new Uint8Array(await crypto.subtle.digest("SHA-256", clientData));
  const composite = new Uint8Array(authData.length + clientDataHash.length);
  composite.set(authData, 0);
  composite.set(clientDataHash, authData.length);
  const nonce = new Uint8Array(await crypto.subtle.digest("SHA-256", composite));
  const rawSig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, nonce),
  );
  return rawSigToDer(rawSig);
}

/// End-to-end convenience: build a full CBOR-encoded assertion (the same
/// shape `verifyAssertion`/`POST /v2/device/assert` expect) for a given
/// team/bundle id, counter and clientData, signed with `privateKey`.
export async function buildSyntheticAssertion(params: {
  teamId: string;
  bundleId: string;
  counter: number;
  clientData: Uint8Array;
  privateKey: CryptoKey;
}): Promise<Uint8Array> {
  const rpHash = await rpIdHashFor(params.teamId, params.bundleId);
  const authData = buildAuthData(rpHash, params.counter);
  const sigDer = await signAssertion(params.privateKey, authData, params.clientData);
  return cborEncode(new Map<string, Uint8Array>([
    ["signature", sigDer],
    ["authenticatorData", authData],
  ]));
}

/// Standard (not URL-safe) base64 of raw bytes — matches the encoding the
/// worker's own `base64Decode`/`arrayBufferToBase64` (index.ts) and the
/// iOS App Attest API use on the wire.
export function toBase64(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}
