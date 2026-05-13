// Per-device token issuance for the Phase B worker-auth redesign.
//
// Replaces the bundled `X-API-Key` (which sits in the IPA's Info.plist
// and was easy to extract). Each install attests its keypair via Apple
// App Attest; the worker verifies the attestation, caches the device's
// public key, and issues a short-lived HMAC-signed bearer token.
//
// This module owns:
//   1. HMAC token issue + verify (production-ready)
//   2. App Attest attestation verification — STUB, see TODO below
//   3. App Attest assertion verification — STUB, see TODO below
//
// See docs/plans/2026-05-13-worker-auth-redesign.md §B1 for the spec
// and the planned pkijs-based attestation chain validation.

const TOKEN_TTL_SECONDS = 15 * 60;          // 15-minute bearer tokens
const HMAC_ALGORITHM = { name: "HMAC", hash: "SHA-256" } as const;

// =====================================================================
// HMAC token issue + verify — production ready
// =====================================================================

export interface TokenPayload {
  deviceId: string;
  scope: string;   // "default" | "mailbox:abc123" | ...
  expires: number; // unix seconds
}

/// Sign a token payload with HMAC-SHA256(env.TOKEN_SECRET). The wire
/// format is `base64url(payload).base64url(signature)` — same shape as
/// JWT's payload+signature halves so debug tooling stays familiar.
export async function issueToken(
  payload: TokenPayload,
  secret: string,
): Promise<string> {
  const payloadJson = JSON.stringify(payload);
  const payloadBytes = new TextEncoder().encode(payloadJson);
  const key = await importHmacKey(secret);
  const sigBytes = new Uint8Array(
    await crypto.subtle.sign(HMAC_ALGORITHM, key, payloadBytes),
  );
  return `${toBase64Url(payloadBytes)}.${toBase64Url(sigBytes)}`;
}

/// Verify a bearer token. Returns the payload on success, throws on any
/// failure mode (malformed, bad signature, expired). Constant-time
/// comparison via SubtleCrypto's `verify`.
export async function verifyToken(
  token: string,
  secret: string,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): Promise<TokenPayload> {
  const parts = token.split(".");
  if (parts.length !== 2) throw new Error("Malformed token");
  const [payloadEncoded, sigEncoded] = parts;
  const payloadBytes = fromBase64Url(payloadEncoded);
  const sigBytes = fromBase64Url(sigEncoded);

  const key = await importHmacKey(secret);
  const valid = await crypto.subtle.verify(
    HMAC_ALGORITHM,
    key,
    sigBytes,
    payloadBytes,
  );
  if (!valid) throw new Error("Invalid signature");

  const payload = JSON.parse(new TextDecoder().decode(payloadBytes)) as TokenPayload;
  if (typeof payload.deviceId !== "string" || typeof payload.scope !== "string" || typeof payload.expires !== "number") {
    throw new Error("Invalid payload shape");
  }
  if (payload.expires < nowSeconds) throw new Error("Token expired");

  return payload;
}

/// Helper: 15-minute token from now.
export function freshTokenPayload(deviceId: string, scope: string = "default"): TokenPayload {
  return {
    deviceId,
    scope,
    expires: Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS,
  };
}

// =====================================================================
// App Attest attestation + assertion verification
// =====================================================================
//
// Implemented in `./appAttest.ts` using `pkijs` + `cbor2` + Web Crypto.
// Re-exported here so route handlers keep the same import surface they
// had when the verifier was stubbed.

export {
  verifyAttestation as verifyAppAttestation,
  verifyAssertion as verifyAppAttestAssertion,
  type AttestationInput as AppAttestVerifyParams,
  type AttestationResult as AppAttestVerifyResult,
  type AssertionInput as AppAttestAssertionParams,
  type AssertionResult as AppAttestAssertionResult,
} from "./appAttest";

/// Kept for back-compat with the stub-era route handlers. Will be
/// removed once those switch to plain `Error` handling.
export class AttestationNotImplemented extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = "AttestationNotImplemented";
  }
}

// =====================================================================
// Helpers — base64url + HMAC key import
// =====================================================================

async function importHmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    HMAC_ALGORITHM,
    false,
    ["sign", "verify"],
  );
}

function toBase64Url(bytes: Uint8Array): string {
  let str = "";
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64Url(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/").padEnd(s.length + (4 - (s.length % 4)) % 4, "=");
  const bin = atob(padded);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}
