// Wire-format types for the /v2/config/crypto-policy endpoint.
// Mirrors PeerDrop/Security/SignedCryptoPolicy.swift exactly — any change
// to the Swift struct shape MUST be reflected here, otherwise the worker
// will serve blobs the client rejects with policy.malformedJSON.

export interface SecurityPolicyShape {
  spkMaxAgeDays: number;
  spkExpirationBehavior: "warn" | "reject";
  opkExhaustionBehavior: {
    legacy: "proceedWithoutDH4" | "failClosed";
    strict: "proceedWithoutDH4" | "failClosed";
  };
  opkRetryMaxAttempts: number;
  opkRetryIntervalSeconds: number;
  skippedKeyTTLDays: number;
  skippedKeyMaxCount: number;
  consumedOPKPruneWindowDays: number;
}

export interface SignedCryptoPolicy {
  schemaVersion: number;
  issuedAt: number;
  expiresAt: number;
  policy: SecurityPolicyShape;
  /** base64 Ed25519 signature over canonical JSON of the other 4 fields */
  signature: string;
}

// Bundled default inlined at build time via the prebuild script.
// Source of truth: cloudflare-worker/bundled-default-policy.signed.json
// Regenerate with: npm run prebuild (or npm run build which calls prebuild first)
import { BUNDLED_DEFAULT_POLICY_JSON } from "./bundledDefaultPolicy";

/**
 * Serves the signed crypto-policy blob.
 *
 * Behavior:
 * - If env.CRYPTO_POLICY_JSON is set (operator override), serves that verbatim.
 * - Otherwise, serves the bundled default from
 *   cloudflare-worker/bundled-default-policy.signed.json (inlined at build).
 *
 * Cache headers:
 * - max-age=3600  — browsers/clients cache for 1 hour
 * - s-maxage=86400 — Cloudflare CDN edge caches for 1 day
 *
 * No auth required — the response is signed; auth would add complexity
 * without raising security.
 */
export async function handleCryptoPolicy(env: { CRYPTO_POLICY_JSON?: string }): Promise<Response> {
  const body = env.CRYPTO_POLICY_JSON ?? BUNDLED_DEFAULT_POLICY_JSON;
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=3600, s-maxage=86400",
      "Access-Control-Allow-Origin": "*",
    },
  });
}
