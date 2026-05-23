/**
 * GET /v2/config/crypto-policy — signed crypto-policy blob endpoint.
 *
 * Coverage:
 *   - Happy path: 200 + bundled-default fields present (schemaVersion, signature, spkMaxAgeDays)
 *   - Operator env override: CRYPTO_POLICY_JSON takes precedence over bundled default
 *   - Cache headers: public, max-age=3600, s-maxage=86400
 *   - CORS: Access-Control-Allow-Origin: *
 */

import { SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { handleCryptoPolicy } from "../cryptoPolicy";

describe("handleCryptoPolicy", () => {
  it("returns 200 with bundled default when env var unset", async () => {
    const res = await handleCryptoPolicy({});
    expect(res.status).toBe(200);
    const body = await res.json() as {
      schemaVersion: number;
      signature: string;
      policy: { spkMaxAgeDays: number };
    };
    expect(body.schemaVersion).toBe(1);
    expect(body.signature).toBeDefined();
    expect(body.policy.spkMaxAgeDays).toBe(21);
  });

  it("returns env override when CRYPTO_POLICY_JSON is set", async () => {
    const override = JSON.stringify({
      schemaVersion: 1,
      issuedAt: 1748000000,
      expiresAt: 1750592000,
      policy: { spkMaxAgeDays: 14 },
      signature: "OVERRIDE_SIG",
    });
    const res = await handleCryptoPolicy({ CRYPTO_POLICY_JSON: override });
    expect(res.status).toBe(200);
    const body = await res.json() as {
      policy: { spkMaxAgeDays: number };
      signature: string;
    };
    expect(body.policy.spkMaxAgeDays).toBe(14);
    expect(body.signature).toBe("OVERRIDE_SIG");
  });

  it("sets correct cache headers", async () => {
    const res = await handleCryptoPolicy({});
    expect(res.headers.get("Cache-Control")).toBe("public, max-age=3600, s-maxage=86400");
    expect(res.headers.get("Content-Type")).toBe("application/json");
  });

  it("sets CORS header", async () => {
    const res = await handleCryptoPolicy({});
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
  });
});

describe("GET /v2/config/crypto-policy (route integration)", () => {
  it("route is reachable and returns 200 without auth", async () => {
    const resp = await SELF.fetch("https://example.com/v2/config/crypto-policy", {
      headers: { "CF-Connecting-IP": "10.0.1.1" },
    });
    expect(resp.status).toBe(200);
    const body = await resp.json() as {
      schemaVersion: number;
      policy: { spkMaxAgeDays: number };
    };
    // Bundled default values
    expect(body.schemaVersion).toBe(1);
    expect(body.policy.spkMaxAgeDays).toBe(21);
  });

  it("POST to the route returns 404 (only GET is handled)", async () => {
    const resp = await SELF.fetch("https://example.com/v2/config/crypto-policy", {
      method: "POST",
      headers: { "CF-Connecting-IP": "10.0.1.2" },
    });
    expect(resp.status).toBe(404);
  });
});
