/**
 * #7 — 測試 src/index.ts 的 KV 限流器（`isRateLimited`、`rateLimitClass`、
 * `rateLimitMax`）。計數器以路由類別、IP 雜湊與分鐘視窗為鍵寫入 KV，讓
 * 不同 isolate／colo 共用預算。每個 (IP、路由類別) 各自計數：groups 為
 * 每分鐘 120 次，其餘類別為每分鐘 30 次。IP 取自 `CF-Connecting-IP`；
 * 缺少標頭時的 "unknown" 刻意不限制，因為 Cloudflare 正式流量一定會帶上
 * 此標頭，合併所有未知呼叫者反而會造成共用桶。
 *
 * 每個測試使用不同的合成 IP，避免計數器在不同測試間互相影響。
 */

import { SELF, env } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { rateLimitMax } from "../index";

const API_KEY = "test-api-key-12345";
// 舊有路由類別測試維持 30 次上限；groups 的額外案例直接測 120 次。
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
  // 限流器會先於 /v3 路由的驗證執行，因此刻意不附憑證。
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
