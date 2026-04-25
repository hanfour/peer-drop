/**
 * /debug/metric ingest + /debug/metrics/stats aggregation.
 *
 * Pins the metric pipeline contract:
 *   - auth gate (API_KEY)
 *   - 4 KB payload cap
 *   - JSON shape validation (must be object with required fields)
 *   - KV-metadata-backed stats aggregation (post Task 3.1.5 perf fix)
 *
 * Each test uses a unique IP to avoid the 30-req/min rate limiter.
 */

import { SELF, env } from "cloudflare:test";
import { describe, it, expect, beforeEach } from "vitest";

const API_KEY = "test-api-key-12345";
const ANALYTICS_KEY = "test-analytics-key-67890";

// Wipe today's metrics + the config key so each test starts from a known
// baseline. We can't list across the whole namespace cheaply, but the only
// metrics we write live under `metric:YYYY-MM-DD:` for today's date.
async function wipeMetrics(): Promise<void> {
  const today = new Date().toISOString().slice(0, 10);
  const list = await env.METRICS.list({ prefix: `metric:${today}:` });
  for (const k of list.keys) {
    await env.METRICS.delete(k.name);
  }
}

beforeEach(async () => {
  await wipeMetrics();
});

function metricBody(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    connectionType: "lan",
    role: "host",
    outcome: { type: "success" },
    durationMs: 1234,
    iceStats: { candidatesUsed: "host" },
    ...overrides,
  });
}

async function postMetric(
  body: string,
  headers: Record<string, string> = {},
  ip = "10.0.1.1",
): Promise<Response> {
  return await SELF.fetch("https://example.com/debug/metric", {
    method: "POST",
    headers: { "Content-Type": "application/json", "CF-Connecting-IP": ip, ...headers },
    body,
  });
}

// --------------------------------------------------------------------------
// Auth + validation
// --------------------------------------------------------------------------

describe("metric-ingest — auth + validation", () => {
  it("returns 401 with no API key", async () => {
    const resp = await postMetric(metricBody(), {}, "10.0.1.10");
    expect(resp.status).toBe(401);
  });

  it("returns 201 with correct key + valid body", async () => {
    const resp = await postMetric(metricBody(), { "X-API-Key": API_KEY }, "10.0.1.11");
    expect(resp.status).toBe(201);
    const body = (await resp.json()) as { ok: boolean; id: string };
    expect(body.ok).toBe(true);
    expect(body.id).toMatch(/^metric:\d{4}-\d{2}-\d{2}:[0-9a-f-]{36}$/);
  });

  it("returns 413 when payload exceeds 4 KB", async () => {
    const huge = "x".repeat(4 * 1024 + 1);
    const resp = await postMetric(
      metricBody({ junk: huge }),
      { "X-API-Key": API_KEY },
      "10.0.1.12",
    );
    expect(resp.status).toBe(413);
    const body = (await resp.json()) as { error: string };
    expect(body.error).toBe("Payload too large");
  });

  it("returns 400 for non-JSON body", async () => {
    const resp = await postMetric(
      "not-json{{{",
      { "X-API-Key": API_KEY },
      "10.0.1.13",
    );
    expect(resp.status).toBe(400);
    const body = (await resp.json()) as { error: string };
    expect(body.error).toBe("Invalid JSON");
  });

  it("returns 400 for JSON array (not an object)", async () => {
    const resp = await postMetric(
      "[1,2,3]",
      { "X-API-Key": API_KEY },
      "10.0.1.14",
    );
    expect(resp.status).toBe(400);
    const body = (await resp.json()) as { error: string };
    expect(body.error).toBe("Expected JSON object");
  });

  it("returns 400 when connectionType is missing", async () => {
    const resp = await postMetric(
      JSON.stringify({ role: "host", outcome: "success" }),
      { "X-API-Key": API_KEY },
      "10.0.1.15",
    );
    expect(resp.status).toBe(400);
  });

  it("returns 400 when role is missing", async () => {
    const resp = await postMetric(
      JSON.stringify({ connectionType: "lan", outcome: "success" }),
      { "X-API-Key": API_KEY },
      "10.0.1.16",
    );
    expect(resp.status).toBe(400);
  });

  it("returns 400 when outcome is missing", async () => {
    const resp = await postMetric(
      JSON.stringify({ connectionType: "lan", role: "host" }),
      { "X-API-Key": API_KEY },
      "10.0.1.17",
    );
    expect(resp.status).toBe(400);
  });
});

// --------------------------------------------------------------------------
// Stats aggregation (round-trip)
// --------------------------------------------------------------------------

describe("metric-ingest — stats aggregation", () => {
  it("aggregates a freshly ingested metric into /debug/metrics/stats", async () => {
    // Ingest 2 successes + 1 failure on 'lan', and 1 abandoned on 'turn'.
    const cases = [
      { connectionType: "lan", role: "host", outcome: { type: "success" }, durationMs: 100, iceStats: { candidatesUsed: "host" } },
      { connectionType: "lan", role: "host", outcome: { type: "success" }, durationMs: 200, iceStats: { candidatesUsed: "host" } },
      { connectionType: "lan", role: "guest", outcome: { type: "failure", reason: "timeout" }, durationMs: 5000 },
      { connectionType: "turn", role: "host", outcome: { type: "abandoned" } },
    ];

    let ipCounter = 30;
    for (const c of cases) {
      const resp = await postMetric(
        JSON.stringify(c),
        { "X-API-Key": API_KEY },
        `10.0.1.${ipCounter++}`,
      );
      expect(resp.status).toBe(201);
    }

    // Fetch stats for the 24h window — uses ANALYTICS_KEY, not API_KEY.
    const stats = await SELF.fetch(
      "https://example.com/debug/metrics/stats?range=24h",
      { headers: { "X-API-Key": ANALYTICS_KEY, "CF-Connecting-IP": "10.0.1.99" } },
    );
    expect(stats.status).toBe(200);
    const body = (await stats.json()) as {
      range: string;
      total: number;
      byType: Record<string, { success: number; failure: number; abandoned: number; p50: number | null; p95: number | null }>;
      candidateUse: Record<string, number>;
      failureReasons: Record<string, number>;
    };

    expect(body.range).toBe("24h");
    expect(body.total).toBe(4);
    expect(body.byType.lan.success).toBe(2);
    expect(body.byType.lan.failure).toBe(1);
    expect(body.byType.lan.abandoned).toBe(0);
    expect(body.byType.turn.abandoned).toBe(1);
    expect(body.candidateUse.host).toBe(2);
    expect(body.failureReasons.timeout).toBe(1);
    // p50/p95 should be populated for lan (3 metrics with durationMs).
    expect(body.byType.lan.p50).not.toBeNull();
    expect(body.byType.lan.p95).not.toBeNull();
  });

  it("returns 401 on /debug/metrics/stats with API_KEY (not ANALYTICS_KEY)", async () => {
    const stats = await SELF.fetch(
      "https://example.com/debug/metrics/stats?range=24h",
      { headers: { "X-API-Key": API_KEY, "CF-Connecting-IP": "10.0.1.50" } },
    );
    expect(stats.status).toBe(401);
  });

  it("returns 400 for invalid range", async () => {
    const stats = await SELF.fetch(
      "https://example.com/debug/metrics/stats?range=bogus",
      { headers: { "X-API-Key": ANALYTICS_KEY, "CF-Connecting-IP": "10.0.1.51" } },
    );
    expect(stats.status).toBe(400);
  });
});
