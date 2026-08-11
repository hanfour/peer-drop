/**
 * #10 — wslog privacy. The diagnostic `wslog:*` entries written on WebSocket
 * upgrade failures used to persist the raw client IP + User-Agent into KV for
 * 7 days, directly contradicting the "no logging of IPs" claim (index.ts:~749)
 * and the /debug/report PII-redaction stance (index.ts:~411).
 *
 * Contract now: no raw IP and no User-Agent are ever persisted. The source is
 * still correlatable via a keyed (HMAC) hash so the diagnostic keeps its value.
 */

import { SELF, env } from "cloudflare:test";
import { describe, it, expect } from "vitest";

interface WsLog {
  reason: string;
  code: string;
  ip?: string;
  ipHash?: string;
  ua?: string;
  userAgent?: string;
}

async function readWsLogForCode(code: string): Promise<{ key: string; raw: string; parsed: WsLog } | null> {
  const list = await env.ROOMS.list({ prefix: "wslog:" });
  for (const k of list.keys) {
    const raw = await env.ROOMS.get(k.name);
    if (!raw) continue;
    const parsed = JSON.parse(raw) as WsLog;
    if (parsed.code === code) return { key: k.name, raw, parsed };
  }
  return null;
}

describe("#10 wslog privacy — room_not_found path", () => {
  it("does not persist the raw client IP or User-Agent", async () => {
    const RAW_IP = "203.0.113.77";
    const RAW_UA = "SecretAgent/1.0-DoNotLog";
    const CODE = "QRSTUV"; // valid [A-Z0-9]{6}, room does not exist

    const resp = await SELF.fetch(`https://example.com/room/${CODE}`, {
      headers: { Upgrade: "websocket", "CF-Connecting-IP": RAW_IP, "User-Agent": RAW_UA },
    });
    expect(resp.status).toBe(404);

    const entry = await readWsLogForCode(CODE);
    expect(entry).not.toBeNull();

    // The serialized blob must contain neither the raw IP nor the UA anywhere.
    expect(entry!.raw.includes(RAW_IP)).toBe(false);
    expect(entry!.raw.includes("SecretAgent")).toBe(false);

    // No raw-IP / UA fields at all.
    expect(entry!.parsed.ip).toBeUndefined();
    expect(entry!.parsed.ua).toBeUndefined();
    expect(entry!.parsed.userAgent).toBeUndefined();
  });

  it("still records a correlatable keyed IP hash (not the raw IP)", async () => {
    const RAW_IP = "198.51.100.9";
    const CODE = "WXYZ23";

    const resp = await SELF.fetch(`https://example.com/room/${CODE}`, {
      headers: { Upgrade: "websocket", "CF-Connecting-IP": RAW_IP },
    });
    expect(resp.status).toBe(404);

    const entry = await readWsLogForCode(CODE);
    expect(entry).not.toBeNull();
    expect(typeof entry!.parsed.ipHash).toBe("string");
    expect(entry!.parsed.ipHash!.length).toBeGreaterThan(0);
    expect(entry!.parsed.ipHash).not.toBe(RAW_IP);
  });
});
