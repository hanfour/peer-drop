// Shared /v3/account test helpers — used by account.spec.ts and
// directory.spec.ts. Extracted (not duplicated) so both specs drive the
// exact same challenge→register flow against the real worker routes.
import { SELF, env } from "cloudflare:test";
import { expect } from "vitest";
import { issueToken, freshTokenPayload } from "../deviceToken";
import { TEST_TOKEN_SECRET } from "./testSecrets";

export function b64(u8: Uint8Array): string { return btoa(String.fromCharCode(...u8)); }

export async function ed25519Pair() {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  // `exportKey` is typed as `Promise<ArrayBuffer | JsonWebKey>` (the JWK
  // half only applies to format "jwk"); the "raw" overload always yields
  // an ArrayBuffer, so narrow it rather than leaving `new Uint8Array(...)`
  // with no matching overload.
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey) as ArrayBuffer);
  return { kp, raw };
}

export async function deviceToken(deviceId: string, scope = "default") {
  return issueToken(freshTokenPayload(deviceId, scope), TEST_TOKEN_SECRET);
}

/**
 * Seed `meta:<mailboxId>` the same way `POST /v2/keys/register` does
 * (a random hex token, `created` timestamp), and return the token — the
 * value `/v3/account/register` now demands as `mailboxToken` to prove the
 * caller owns the mailbox it is binding to the account.
 */
export async function seedMailbox(mailboxId: string): Promise<string> {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const token = Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
  await env.V2_STORE.put(`meta:${mailboxId}`, JSON.stringify({ token, created: Date.now() }));
  return token;
}

/** The exact bytes `verifyRegistrationSignature` reconstructs (v2 message). */
export function registrationMessage(nonceBytes: Uint8Array, deviceId: string, bound: Uint8Array): Uint8Array {
  const enc = new TextEncoder();
  return new Uint8Array([...enc.encode("peerdrop-account-v2"), ...nonceBytes, ...enc.encode(deviceId), ...bound]);
}

// Fetches a challenge nonce for `deviceId` and signs it, returning the
// base64 nonce + signature the register route expects. Factored out of
// registerDevice so the identity_bound conflict test (which needs two
// independent devices/keys sharing a forced identityKey) can drive the
// same challenge→sign flow without duplicating it.
//
// The signed message binds the identity key and mailbox id as well (v2),
// so both must be passed in — a signature made for one (identityKey,
// mailboxId) pair is not valid for another.
export async function challengeAndSign(
  deviceId: string,
  tok: string,
  privateKey: CryptoKey,
  identityKey: Uint8Array,
  mailboxId: string,
): Promise<{ nonce: string; signature: string }> {
  const ch = await SELF.fetch("https://example.com/v3/account/challenge", {
    method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
    body: JSON.stringify({ deviceId }),
  });
  expect(ch.status).toBe(201);
  const { nonce } = await ch.json() as { nonce: string };
  const nonceBytes = Uint8Array.from(atob(nonce), (c) => c.charCodeAt(0));
  const bound = new Uint8Array(await crypto.subtle.digest(
    "SHA-256",
    new Uint8Array([...identityKey, ...new TextEncoder().encode(mailboxId)]),
  ));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, privateKey, registrationMessage(nonceBytes, deviceId, bound)));
  return { nonce, signature: b64(sig) };
}

// 32 bytes derived from the WHOLE deviceId (not just first/last char) so
// distinct device ids never collide under the accounts.identity_key
// UNIQUE constraint by coincidence.
export async function identityKeyForDevice(deviceId: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("identity:" + deviceId)));
}

export function mailboxIdForDevice(deviceId: string): string {
  return `mbx${deviceId.replace(/-/g, "")}`;
}

export async function registerDevice(
  deviceId: string,
  platform = "ios",
  pair?: { kp: CryptoKeyPair; raw: Uint8Array },
  opts: { identityKey?: Uint8Array; mailboxId?: string } = {},
) {
  const p = pair ?? await ed25519Pair();
  const tok = await deviceToken(deviceId);
  const identityKey = opts.identityKey ?? await identityKeyForDevice(deviceId);
  const mailboxId = opts.mailboxId ?? mailboxIdForDevice(deviceId);
  const mailboxToken = await seedMailbox(mailboxId);
  const { nonce, signature } = await challengeAndSign(deviceId, tok, p.kp.privateKey, identityKey, mailboxId);
  const reg = await SELF.fetch("https://example.com/v3/account/register", {
    method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
    body: JSON.stringify({ deviceId, platform, identityKey: b64(identityKey), signingKey: b64(p.raw), mailboxId, mailboxToken, nonce, signature }),
  });
  return { reg, pair: p, mailboxId, mailboxToken, identityKey };
}

// Any test that drives a minute-bucketed KV counter (e.g.
// `dir-quota:<accountId>:<minuteWindow>` in /v3/directory) is flaky right
// near a minute boundary: a batch of "same minute" requests can straddle
// two buckets if real time ticks over mid-run. Call this at the top of
// such a test to guarantee at least 5 fresh seconds before firing the
// batch — cheap in the overwhelmingly common case (no-op unless already
// within the last 5s of the current minute).
export async function waitForFreshMinute(): Promise<void> {
  const msIntoMinute = Date.now() % 60_000;
  if (msIntoMinute > 55_000) {
    await new Promise((r) => setTimeout(r, 60_000 - msIntoMinute + 50));
  }
}
