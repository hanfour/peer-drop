/**
 * #7 — Rate limiter. Coverage for the KV-backed limiter in src/index.ts
 * (`isRateLimited`, `rateLimitClass`).
 *
 * The old limiter was a module-level `Map` living in one isolate's memory:
 * Cloudflare runs many isolates across many colos, so each isolate handed out
 * its own independent 30/min budget → the effective global limit was
 * unbounded. The replacement stores a windowed counter in KV keyed by
 * (route class + keyed IP hash + minute window), so the budget is shared
 * across isolates/colos.
 *
 * Limits: 30 requests per RATE_LIMIT_WINDOW_MS = 60_000ms by default (120 for
 * the `groups` class, see `rateLimitMax`), per (IP, route class). Keyed by `CF-Connecting-IP`; the header-absent
 * "unknown" case is intentionally NOT limited (it only occurs off-edge / in
 * tests — Cloudflare always populates CF-Connecting-IP for real traffic, so a
 * shared "unknown" bucket would only merge unrelated callers).
 *
 * Each test below uses a unique synthetic IP so counters never bleed between
 * tests regardless of storage-isolation mode.
 */

import { SELF, env } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { rateLimitMax } from "../index";

const API_KEY = "test-api-key-12345";
// Default per-class limit; the groups cases below assert 120 explicitly.
const RATE_LIMIT_MAX_REQUESTS = 30;

async function pingRoom(ip: string): Promise<Response> {
  // POST /room is auth-gated, but the rate limiter runs *before* the auth
  // check, so any request shape works as long as we send a real method/path
  // the worker handles. Using POST /room with a valid key keeps each call a
  // clean 201 (until rate limit kicks in). Route class = "room".
  return await SELF.fetch("https://example.com/room", {
    method: "POST",
    headers: { "X-API-Key": API_KEY, "CF-Connecting-IP": ip },
  });
}

async function pingDebugReport(ip: string): Promise<Response> {
  // Unauthenticated route; route class = "debug". Minimal valid body → 201.
  return await SELF.fetch("https://example.com/debug/report", {
    method: "POST",
    headers: { "Content-Type": "application/json", "CF-Connecting-IP": ip },
    body: JSON.stringify({ type: "test", error: "x" }),
  });
}

async function pingV3Path(path: string, ip: string): Promise<Response> {
  // The limiter runs before /v3 auth, so no credentials are sent on purpose.
  return await SELF.fetch(`https://example.com${path}`, {
    headers: { "CF-Connecting-IP": ip },
  });
}

describe("rate-limit — route-class budgets", () => {
  it("returns the configured limit for groups and the default for other classes", () => {
    expect(rateLimitMax("groups")).toBe(120);
    expect(rateLimitMax("v3")).toBe(30);
    expect(rateLimitMax("unknown-class")).toBe(30);
  });

  it("allows 120 group requests and returns 429 on the 121st", async () => {
    const ip = "10.0.0.220";
    for (let i = 0; i < 120; i++) {
      expect((await pingV3Path("/v3/groups", ip)).status).not.toBe(429);
    }
    expect((await pingV3Path("/v3/groups", ip)).status).toBe(429);
  });

  it("keeps the v3 diaries limit at 30 requests", async () => {
    const ip = "10.0.0.221";
    for (let i = 0; i < RATE_LIMIT_MAX_REQUESTS; i++) {
      expect((await pingV3Path("/v3/diaries", ip)).status).not.toBe(429);
    }
    expect((await pingV3Path("/v3/diaries", ip)).status).toBe(429);
  });
});

describe("rate-limit — per-IP counter", () => {
  it("allows 30 sequential requests from the same IP", async () => {
    const ip = "10.0.0.100";
    for (let i = 0; i < RATE_LIMIT_MAX_REQUESTS; i++) {
      const resp = await pingRoom(ip);
      expect(resp.status).toBe(201);
    }
  });

  it("returns 429 on the 31st request from the same IP", async () => {
    const ip = "10.0.0.101";
    // Burn through the allowed quota.
    for (let i = 0; i < RATE_LIMIT_MAX_REQUESTS; i++) {
      const resp = await pingRoom(ip);
      expect(resp.status).toBe(201);
    }
    // 31st should hit 429 with Retry-After.
    const tripped = await pingRoom(ip);
    expect(tripped.status).toBe(429);
    expect(tripped.headers.get("Retry-After")).toBe("60");
    const body = (await tripped.json()) as { error: string };
    expect(body.error).toBe("Too many requests");
  });

  it("isolates counters between different IPs", async () => {
    const ipA = "10.0.0.102";
    const ipB = "10.0.0.103";

    // Burn IP A to its limit.
    for (let i = 0; i < RATE_LIMIT_MAX_REQUESTS; i++) {
      const resp = await pingRoom(ipA);
      expect(resp.status).toBe(201);
    }
    expect((await pingRoom(ipA)).status).toBe(429);

    // IP B is still unaffected — first request must succeed.
    const respB = await pingRoom(ipB);
    expect(respB.status).toBe(201);
  });
});

describe("rate-limit — KV-backed (shared across isolates, not a module Map)", () => {
  it("persists the counter to a KV `rl:` key rather than in-isolate memory", async () => {
    const ip = "10.0.0.200";
    for (let i = 0; i < 3; i++) {
      expect((await pingRoom(ip)).status).toBe(201);
    }

    // If the limiter kept state in a module-level Map (per isolate), nothing
    // would ever be written to KV. A shared, cross-isolate limiter must leave
    // its counter in the durable store.
    const list = await env.ROOMS.list({ prefix: "rl:" });
    let total = 0;
    let found = false;
    for (const k of list.keys) {
      const v = await env.ROOMS.get(k.name);
      if (v !== null) {
        found = true;
        total += parseInt(v, 10) || 0;
      }
    }
    expect(found).toBe(true);
    expect(total).toBeGreaterThanOrEqual(3);
  });

  it("keys the budget by route class — exhausting one class does not block another", async () => {
    const ip = "10.0.0.210";

    // Exhaust the "room" class.
    for (let i = 0; i < RATE_LIMIT_MAX_REQUESTS; i++) {
      expect((await pingRoom(ip)).status).toBe(201);
    }
    expect((await pingRoom(ip)).status).toBe(429);

    // A different route class ("debug") from the SAME IP has its own budget.
    // (The old global Map counted every route together, so this would 429.)
    const debugResp = await pingDebugReport(ip);
    expect(debugResp.status).toBe(201);
  });
});
