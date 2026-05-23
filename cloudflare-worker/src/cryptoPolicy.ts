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
