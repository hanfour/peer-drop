/**
 * #6 / #6b — PreKeyStore one-time-prekey (OTPK) consumption.
 *
 * #6  OTPK-exhaustion DoS: GET /v2/keys/:mailboxId is (correctly) unauthed —
 *     it's the pre-session X3DH bootstrap an initiator must reach before any
 *     session/mailbox exists. But an attacker could hammer it to drain the
 *     victim's OTPK pool, and under a strict client policy that fails closed
 *     the victim becomes unreachable. Fix: rate-limit *consumption* per mailbox
 *     and, when the pool is exhausted or the rate cap is hit, return a valid
 *     SPK-only bundle (X3DH without an OTPK) rather than an error — the peer
 *     stays reachable.
 *
 * #6b Consumption race: the DO read bundle from KV, shift()ed one OTPK, and
 *     wrote it back — with await points (KV get/put) that are NOT covered by
 *     DO input gating, so two concurrent initiators could read the same
 *     snapshot and be handed the *same* OTPK. Fix: serialize the read-modify-
 *     write so concurrent consumers get distinct OTPKs.
 */

import { SELF, env } from "cloudflare:test";
import { describe, it, expect } from "vitest";

interface Bundle {
  identityKey: string;
  signingKey: string;
  signedPreKey: unknown;
  oneTimePreKey: string | null;
}

async function registerBundle(mailboxId: string, otpkCount: number): Promise<void> {
  const oneTimePreKeys = Array.from({ length: otpkCount }, (_, i) => `otpk-${mailboxId}-${i}`);
  const resp = await SELF.fetch("https://example.com/v2/keys/register", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      mailboxId,
      preKeyBundle: {
        identityKey: `ik-${mailboxId}`,
        signingKey: `sk-${mailboxId}`,
        signedPreKey: `spk-${mailboxId}`,
        oneTimePreKeys,
      },
    }),
  });
  expect(resp.status).toBe(201);
}

async function consume(mailboxId: string): Promise<Bundle> {
  const resp = await SELF.fetch(`https://example.com/v2/keys/${mailboxId}`);
  expect(resp.status).toBe(200);
  return (await resp.json()) as Bundle;
}

async function poolSize(mailboxId: string): Promise<number> {
  const raw = await env.V2_STORE.get(`keys:${mailboxId}`);
  if (!raw) return -1;
  const b = JSON.parse(raw) as { oneTimePreKeys?: unknown[] };
  return b.oneTimePreKeys?.length ?? 0;
}

describe("#6 OTPK consumption — normal low-rate behaviour unchanged", () => {
  it("hands out a fresh OTPK on a normal single consume", async () => {
    const mbx = "mbxnormal01";
    await registerBundle(mbx, 5);
    const b = await consume(mbx);
    expect(b.oneTimePreKey).toBe(`otpk-${mbx}-0`);
    expect(b.identityKey).toBe(`ik-${mbx}`);
    expect(await poolSize(mbx)).toBe(4);
  });

  it("returns a valid SPK-only bundle (not an error) when the pool is empty", async () => {
    const mbx = "mbxempty01";
    await registerBundle(mbx, 0);
    const b = await consume(mbx);
    expect(b.oneTimePreKey).toBeNull();
    // SPK bundle is still complete → peer remains reachable.
    expect(b.identityKey).toBe(`ik-${mbx}`);
    expect(b.signedPreKey).toBe(`spk-${mbx}`);
  });
});

describe("#6 OTPK exhaustion DoS — consumption is rate-limited", () => {
  it("caps fresh OTPKs per window and serves SPK-only beyond the cap, leaving the pool intact", async () => {
    const mbx = "mbxburst01";
    // Pool far larger than the per-window cap so any SPK-only response after
    // the cap is due to the RATE LIMIT, not exhaustion.
    await registerBundle(mbx, 30);

    const results: Bundle[] = [];
    for (let i = 0; i < 15; i++) {
      results.push(await consume(mbx));
    }

    const withOtpk = results.filter((r) => r.oneTimePreKey !== null);
    const withoutOtpk = results.filter((r) => r.oneTimePreKey === null);

    // A meaningful cap: some requests were served fresh OTPKs, and the burst
    // was throttled (not all 15 drained the pool).
    expect(withOtpk.length).toBeGreaterThan(0);
    expect(withoutOtpk.length).toBeGreaterThan(0);
    expect(withOtpk.length).toBeLessThan(15);

    // The throttled responses are still valid SPK bundles.
    for (const r of withoutOtpk) {
      expect(r.identityKey).toBe(`ik-${mbx}`);
      expect(r.signedPreKey).toBe(`spk-${mbx}`);
    }

    // The OTPKs that WERE handed out are all distinct (no double-issue).
    const issued = withOtpk.map((r) => r.oneTimePreKey);
    expect(new Set(issued).size).toBe(issued.length);

    // Crucially: the pool was NOT drained by the burst — the rate limit
    // stopped consumption well before exhaustion, so the victim keeps most
    // of its OTPKs for legitimate peers.
    expect(await poolSize(mbx)).toBeGreaterThanOrEqual(15);
  });
});

describe("#6b OTPK consumption race — concurrent consumers get distinct OTPKs", () => {
  it("never hands the same OTPK to two concurrent initiators", async () => {
    const mbx = "mbxrace01";
    await registerBundle(mbx, 5);

    // Fire concurrently. Without a serialized read-modify-write, several of
    // these read the same pre-shift snapshot and are handed the SAME OTPK.
    const bundles = await Promise.all([
      consume(mbx), consume(mbx), consume(mbx), consume(mbx), consume(mbx),
    ]);

    const issued = bundles.map((b) => b.oneTimePreKey).filter((k): k is string => k !== null);
    // Every OTPK actually handed out must be unique.
    expect(new Set(issued).size).toBe(issued.length);
  });
});
