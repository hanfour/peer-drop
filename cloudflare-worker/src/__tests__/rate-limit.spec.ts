/**
 * Per-IP rate limiter — coverage for src/index.ts:55-72 (`isRateLimited`).
 *
 * Limits: RATE_LIMIT_MAX_REQUESTS = 30 / RATE_LIMIT_WINDOW_MS = 60_000ms.
 * Keyed by the `CF-Connecting-IP` header, falling back to `"unknown"`.
 *
 * Note on isolation: `rateLimitMap` is module-level and persists across
 * SELF.fetch calls within a single isolate. Each test below uses a unique
 * synthetic IP to avoid bleeding counter state between tests.
 *
 * Note on the window-reset case: the limiter reads wallclock `Date.now()`,
 * and miniflare/vitest fake timers don't reliably advance the clock that the
 * Worker isolate observes (the Worker runs in a separate workerd process).
 * We document the limitation rather than ship a flaky test — see the skipped
 * case at the bottom of this file.
 */

import { SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";

const API_KEY = "test-api-key-12345";
const RATE_LIMIT_MAX_REQUESTS = 30;

async function pingRoom(ip: string): Promise<Response> {
  // POST /room is auth-gated, but the rate limiter runs *before* the auth
  // check, so any request shape works as long as we send a real method/path
  // the worker handles. Using POST /room with a valid key keeps each call a
  // clean 201 (until rate limit kicks in).
  return await SELF.fetch("https://example.com/room", {
    method: "POST",
    headers: { "X-API-Key": API_KEY, "CF-Connecting-IP": ip },
  });
}

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

  // The reset path (window expires → counter resets to 1) requires advancing
  // wallclock past 60 seconds inside the worker isolate. miniflare's fake
  // timers operate at the test side, not inside workerd, so we cannot drive
  // `Date.now()` forward in `isRateLimited`. Real-time waiting 60+ seconds in
  // CI is wasteful and flaky — option (a) from the task spec applies.
  //
  // The reset code path itself is trivial (3 lines of arithmetic) and is
  // exercised by the IP-isolation test above (each test uses a fresh IP key,
  // which goes through the `!entry` branch — same code as the reset branch).
  it.skip("resets counter after RATE_LIMIT_WINDOW_MS elapses (skipped — see comment)", () => {
    // Intentionally skipped: cannot reliably advance the worker isolate's
    // wallclock from vitest. The reset branch is logically symmetric to the
    // first-request branch which IS covered by the isolation test.
  });
});
