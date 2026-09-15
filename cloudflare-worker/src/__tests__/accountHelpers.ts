// Shared /v3/account test helpers — used by account.spec.ts and
// directory.spec.ts. Extracted (not duplicated) so both specs drive the
// exact same challenge→register flow against the real worker routes.
import { SELF } from "cloudflare:test";
import { expect } from "vitest";
import { issueToken, freshTokenPayload } from "../deviceToken";
import { TEST_TOKEN_SECRET } from "./testSecrets";

export function b64(u8: Uint8Array): string { return btoa(String.fromCharCode(...u8)); }

export async function ed25519Pair() {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  return { kp, raw };
}

export async function deviceToken(deviceId: string, scope = "default") {
  return issueToken(freshTokenPayload(deviceId, scope), TEST_TOKEN_SECRET);
}

// Fetches a challenge nonce for `deviceId` and signs it, returning the
// base64 nonce + signature the register route expects. Factored out of
// registerDevice so the identity_bound conflict test (which needs two
// independent devices/keys sharing a forced identityKey) can drive the
// same challenge→sign flow without duplicating it.
export async function challengeAndSign(deviceId: string, tok: string, privateKey: CryptoKey): Promise<{ nonce: string; signature: string }> {
  const ch = await SELF.fetch("https://example.com/v3/account/challenge", {
    method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
    body: JSON.stringify({ deviceId }),
  });
  expect(ch.status).toBe(201);
  const { nonce } = await ch.json() as { nonce: string };
  const nonceBytes = Uint8Array.from(atob(nonce), (c) => c.charCodeAt(0));
  const msg = new Uint8Array([...new TextEncoder().encode("peerdrop-account-v1"), ...nonceBytes, ...new TextEncoder().encode(deviceId)]);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, privateKey, msg));
  return { nonce, signature: b64(sig) };
}

// 32 bytes derived from the WHOLE deviceId (not just first/last char) so
// distinct device ids never collide under the accounts.identity_key
// UNIQUE constraint by coincidence.
export async function identityKeyForDevice(deviceId: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("identity:" + deviceId)));
}

export async function registerDevice(deviceId: string, platform = "ios", pair?: { kp: CryptoKeyPair; raw: Uint8Array }) {
  const p = pair ?? await ed25519Pair();
  const tok = await deviceToken(deviceId);
  const { nonce, signature } = await challengeAndSign(deviceId, tok, p.kp.privateKey);
  const identityKey = await identityKeyForDevice(deviceId);
  const reg = await SELF.fetch("https://example.com/v3/account/register", {
    method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
    body: JSON.stringify({ deviceId, platform, identityKey: b64(identityKey), signingKey: b64(p.raw), mailboxId: `mbx${deviceId.replace(/-/g, "")}`, nonce, signature }),
  });
  return { reg, pair: p };
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
