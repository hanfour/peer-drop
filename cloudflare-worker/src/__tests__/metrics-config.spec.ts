/**
 * /config/metrics — public remote circuit breaker.
 *
 * Public (no auth) on purpose: the iOS client polls this on every metric
 * submission to decide whether to send. Failure here must NOT prevent the
 * client from picking sane defaults — hence the fail-open semantics.
 *
 * Regression guard for commit 9e1dc1e (fix: /config/metrics fails open on
 * malformed KV JSON).
 */

import { SELF, env } from "cloudflare:test";
import { describe, it, expect, beforeEach } from "vitest";

interface Config {
  sampleRate: number;
  enabled: boolean;
}

beforeEach(async () => {
  await env.METRICS.delete("config:metrics");
});

describe("/config/metrics", () => {
  it("is public — no API key needed", async () => {
    const resp = await SELF.fetch("https://example.com/config/metrics", {
      headers: { "CF-Connecting-IP": "10.0.2.1" },
    });
    expect(resp.status).toBe(200);
  });

  it("returns the default { sampleRate: 1, enabled: true } before any KV state is set", async () => {
    const resp = await SELF.fetch("https://example.com/config/metrics", {
      headers: { "CF-Connecting-IP": "10.0.2.2" },
    });
    expect(resp.status).toBe(200);
    const cfg = (await resp.json()) as Config;
    expect(cfg.sampleRate).toBe(1);
    expect(cfg.enabled).toBe(true);
  });

  it("reflects KV state when valid JSON is written", async () => {
    await env.METRICS.put(
      "config:metrics",
      JSON.stringify({ sampleRate: 0.5, enabled: false }),
    );
    const resp = await SELF.fetch("https://example.com/config/metrics", {
      headers: { "CF-Connecting-IP": "10.0.2.3" },
    });
    expect(resp.status).toBe(200);
    const cfg = (await resp.json()) as Config;
    expect(cfg.sampleRate).toBe(0.5);
    expect(cfg.enabled).toBe(false);
  });

  it("fails open on malformed KV JSON (regression guard for 9e1dc1e)", async () => {
    await env.METRICS.put("config:metrics", "not-json{{{");
    const resp = await SELF.fetch("https://example.com/config/metrics", {
      headers: { "CF-Connecting-IP": "10.0.2.4" },
    });
    expect(resp.status).toBe(200);
    const cfg = (await resp.json()) as Config;
    // Falls back to safe defaults, NOT a 500 — clients must always get a
    // usable config shape.
    expect(cfg).toEqual({ sampleRate: 1, enabled: true });
  });
});
