/**
 * /debug/crypto-metric ingest + /debug/crypto-metrics/stats aggregation.
 *
 * Feeds the v5.4 crypto-hardening soak (spec §8.6): the app posts
 * CryptoHardeningMetrics.snapshot() counters here; the stats endpoint
 * sums the soak-gate counters (c1 invalid-sig, c2 failed-initiation,
 * policy signature-invalid) over a window so activation of strict policy
 * can be gated on real production numbers.
 *
 * Auth is header-only (isHeaderAuthorized) — same rationale as
 * /debug/metric: no `?apiKey=` query lane on a plain POST.
 * Each test uses a unique IP to dodge the 30-req/min rate limiter.
 */

import { SELF, env } from "cloudflare:test";
import { describe, it, expect, beforeEach } from "vitest";
import { issueToken, freshTokenPayload } from "../deviceToken";
import { TEST_API_KEY as API_KEY, TEST_ANALYTICS_KEY as ANALYTICS_KEY, TEST_TOKEN_SECRET as TOKEN_SECRET } from "./testSecrets";

async function wipe(): Promise<void> {
  const today = new Date().toISOString().slice(0, 10);
  const list = await env.METRICS.list({ prefix: `cryptometric:${today}:` });
  for (const k of list.keys) await env.METRICS.delete(k.name);
}

beforeEach(async () => { await wipe(); });

function cryptoBody(counters: Record<string, number> = {}): string {
  return JSON.stringify({
    counters: {
      "c1.spk_timestamp_valid": 10,
      "c1.spk_timestamp_invalid_signature": 0,
      "c2.opk_failed_initiation": 0,
      "policy.signature_invalid": 0,
      ...counters,
    },
    keyedCounters: [],
    platform: "ios",
    appVersion: "5.6.0",
    timestamp: "2026-07-05T00:00:00Z",
  });
}

async function post(body: string, headers: Record<string, string> = {}, ip = "10.5.0.1"): Promise<Response> {
  return await SELF.fetch("https://example.com/debug/crypto-metric", {
    method: "POST",
    headers: { "Content-Type": "application/json", "CF-Connecting-IP": ip, ...headers },
    body,
  });
}

describe("crypto-metric ingest — auth + validation", () => {
  it("returns 401 with no credential", async () => {
    expect((await post(cryptoBody(), {}, "10.5.0.10")).status).toBe(401);
  });

  it("returns 201 with the operator X-API-Key", async () => {
    const resp = await post(cryptoBody(), { "X-API-Key": API_KEY }, "10.5.0.11");
    expect(resp.status).toBe(201);
    const b = (await resp.json()) as { ok: boolean; id: string };
    expect(b.ok).toBe(true);
    expect(b.id).toMatch(/^cryptometric:\d{4}-\d{2}-\d{2}:[0-9a-f-]{36}$/);
  });

  it("returns 201 with a valid App-Attest Bearer token", async () => {
    const token = await issueToken(freshTokenPayload("crypto-dev-1"), TOKEN_SECRET);
    expect((await post(cryptoBody(), { Authorization: `Bearer ${token}` }, "10.5.0.12")).status).toBe(201);
  });

  it("returns 401 when the key is passed as a query param (no URL-credential lane)", async () => {
    const resp = await SELF.fetch(`https://example.com/debug/crypto-metric?apiKey=${API_KEY}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "10.5.0.13" },
      body: cryptoBody(),
    });
    expect(resp.status).toBe(401);
  });

  it("returns 400 when `counters` is missing (leaked key can't flood arbitrary blobs)", async () => {
    const resp = await post(JSON.stringify({ platform: "ios" }), { "X-API-Key": API_KEY }, "10.5.0.14");
    expect(resp.status).toBe(400);
  });

  it("returns 400 for a non-object body", async () => {
    expect((await post("[1,2,3]", { "X-API-Key": API_KEY }, "10.5.0.15")).status).toBe(400);
  });

  it("returns 413 only when the payload exceeds the 8 KB cap", async () => {
    const huge: Record<string, number> = {};
    for (let i = 0; i < 4000; i++) huge[`junk.counter.number.${i}`] = i;
    expect((await post(cryptoBody(huge), { "X-API-Key": API_KEY }, "10.5.0.16")).status).toBe(413);
  });

  it("accepts a realistically-large multi-peer snapshot (was 413 under the old 2 KB cap)", async () => {
    // ~70 keyedCounters (23 kinds × a few peer versions) ≈ 4-5 KB.
    const keyed = [];
    const kinds = ["c1.spk_timestamp_valid", "c2.opk_failed_initiation", "policy.signature_invalid"];
    for (let i = 0; i < 70; i++) {
      keyed.push({ kind: kinds[i % kinds.length], peerVersion: `v5_4_plus_variant_${i}`, count: i });
    }
    const body = JSON.stringify({ counters: { "c1.spk_timestamp_valid": 5 }, keyedCounters: keyed, platform: "ios", appVersion: "5.6.0", timestamp: "2026-07-05T00:00:00Z" });
    expect(body.length).toBeGreaterThan(2 * 1024); // would have 413'd before
    expect((await post(body, { "X-API-Key": API_KEY }, "10.5.0.17")).status).toBe(201);
  });

  it("clamps a hostile negative counter to zero (can't poison the fleet sum)", async () => {
    await post(cryptoBody({ "policy.signature_invalid": 3 }), { "X-API-Key": API_KEY }, "10.5.0.40");
    // A single client tries to drive the fleet sum negative.
    await post(cryptoBody({ "policy.signature_invalid": -1000000 }), { "X-API-Key": API_KEY }, "10.5.0.41");

    const stats = await SELF.fetch("https://example.com/debug/crypto-metrics/stats?range=24h", {
      headers: { "X-API-Key": ANALYTICS_KEY, "CF-Connecting-IP": "10.5.0.42" },
    });
    const b = (await stats.json()) as { soak: { policySignatureInvalid: number } };
    // The hostile -1000000 was clamped to 0; the honest 3 stands.
    expect(b.soak.policySignatureInvalid).toBe(3);
  });
});

describe("crypto-metric stats — aggregation", () => {
  it("sums soak-gate counters across ingested snapshots", async () => {
    let ip = 30;
    // Two snapshots: one clean, one with a policy-signature-invalid blip.
    await post(cryptoBody({ "c1.spk_timestamp_invalid_signature": 0 }), { "X-API-Key": API_KEY }, `10.5.0.${ip++}`);
    await post(cryptoBody({ "policy.signature_invalid": 2, "c2.opk_failed_initiation": 1 }), { "X-API-Key": API_KEY }, `10.5.0.${ip++}`);

    const stats = await SELF.fetch("https://example.com/debug/crypto-metrics/stats?range=24h", {
      headers: { "X-API-Key": ANALYTICS_KEY, "CF-Connecting-IP": "10.5.0.99" },
    });
    expect(stats.status).toBe(200);
    const b = (await stats.json()) as {
      range: string; snapshots: number;
      soak: { spkInvalidSignature: number; opkFailedInitiation: number; policySignatureInvalid: number };
    };
    expect(b.range).toBe("24h");
    expect(b.snapshots).toBe(2);
    expect(b.soak.spkInvalidSignature).toBe(0);
    expect(b.soak.opkFailedInitiation).toBe(1);
    expect(b.soak.policySignatureInvalid).toBe(2);
  });

  it("returns 401 on stats with API_KEY instead of ANALYTICS_KEY", async () => {
    const stats = await SELF.fetch("https://example.com/debug/crypto-metrics/stats?range=24h", {
      headers: { "X-API-Key": API_KEY, "CF-Connecting-IP": "10.5.0.50" },
    });
    expect(stats.status).toBe(401);
  });

  it("returns 400 for an invalid range", async () => {
    const stats = await SELF.fetch("https://example.com/debug/crypto-metrics/stats?range=bogus", {
      headers: { "X-API-Key": ANALYTICS_KEY, "CF-Connecting-IP": "10.5.0.51" },
    });
    expect(stats.status).toBe(400);
  });
});
