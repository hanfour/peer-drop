/**
 * Device-token issuance + verification (Phase B1).
 *
 * The HMAC layer is production-ready; the App Attest verifier is a stub
 * that returns 501. Tests pin both contracts so:
 *   - the stub-mode shape (501 with `stub: true`) stays stable while the
 *     iOS client wires up its fallback path,
 *   - the HMAC sign/verify round-trip survives any future refactor.
 */

import { SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { issueToken, verifyToken, freshTokenPayload } from "../deviceToken";

const TEST_SECRET = "test-token-secret-deterministic";
const API_KEY = "test-api-key-12345";

describe("HMAC token round-trip", () => {
  it("verifies a token issued from the same secret", async () => {
    const token = await issueToken(
      { deviceId: "abc-12345678", scope: "default", expires: Math.floor(Date.now() / 1000) + 60 },
      TEST_SECRET,
    );
    const payload = await verifyToken(token, TEST_SECRET);
    expect(payload.deviceId).toBe("abc-12345678");
    expect(payload.scope).toBe("default");
  });

  it("rejects a token signed with a different secret", async () => {
    const token = await issueToken(
      { deviceId: "abc-12345678", scope: "default", expires: Math.floor(Date.now() / 1000) + 60 },
      TEST_SECRET,
    );
    await expect(verifyToken(token, "other-secret")).rejects.toThrow(/Invalid signature/);
  });

  it("rejects a tampered payload", async () => {
    const token = await issueToken(
      freshTokenPayload("abc-12345678"),
      TEST_SECRET,
    );
    const [_payload, sig] = token.split(".");
    const tampered = `${btoa('{"deviceId":"evil","scope":"default","expires":9999999999}').replace(/=+$/, "")}.${sig}`;
    await expect(verifyToken(tampered, TEST_SECRET)).rejects.toThrow(/Invalid signature/);
  });

  it("rejects an expired token", async () => {
    const token = await issueToken(
      { deviceId: "abc-12345678", scope: "default", expires: Math.floor(Date.now() / 1000) - 1 },
      TEST_SECRET,
    );
    await expect(verifyToken(token, TEST_SECRET)).rejects.toThrow(/Token expired/);
  });

  it("rejects a malformed token", async () => {
    await expect(verifyToken("not.a.real.token", TEST_SECRET)).rejects.toThrow(/Malformed/);
    await expect(verifyToken("singlepart", TEST_SECRET)).rejects.toThrow(/Malformed/);
  });

  it("freshTokenPayload sets a 15-minute expiry from now", () => {
    const before = Math.floor(Date.now() / 1000);
    const payload = freshTokenPayload("device-1");
    const after = Math.floor(Date.now() / 1000);
    expect(payload.expires).toBeGreaterThanOrEqual(before + 15 * 60);
    expect(payload.expires).toBeLessThanOrEqual(after + 15 * 60);
    expect(payload.scope).toBe("default");
  });
});

describe("/v2/device/attest (stub mode)", () => {
  it("returns 501 with stub flag when verifier not yet implemented", async () => {
    const resp = await SELF.fetch("https://worker.test/v2/device/attest", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "1.2.3.4" },
      body: JSON.stringify({
        deviceId: "abc-12345678",
        attestation: btoa("fake-cbor-blob"),
        keyId: btoa("fake-key-id"),
        challenge: btoa("fake-challenge"),
      }),
    });
    expect(resp.status).toBe(501);
    const body = await resp.json() as { stub?: boolean };
    expect(body.stub).toBe(true);
  });

  it("returns 400 on missing fields before reaching the verifier", async () => {
    const resp = await SELF.fetch("https://worker.test/v2/device/attest", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "1.2.3.5" },
      body: JSON.stringify({ deviceId: "abc-12345678" }),
    });
    expect(resp.status).toBe(400);
  });

  it("returns 400 on bad deviceId format", async () => {
    const resp = await SELF.fetch("https://worker.test/v2/device/attest", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "1.2.3.6" },
      body: JSON.stringify({
        deviceId: "BAD CHARS!",
        attestation: btoa("x"),
        keyId: btoa("x"),
        challenge: btoa("x"),
      }),
    });
    expect(resp.status).toBe(400);
  });
});

describe("/v2/device/assert (stub mode)", () => {
  it("returns 404 when device hasn't been attested", async () => {
    const resp = await SELF.fetch("https://worker.test/v2/device/assert", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "1.2.3.7" },
      body: JSON.stringify({
        deviceId: "never-seen-this-device",
        assertion: btoa("x"),
        clientData: btoa("x"),
      }),
    });
    expect(resp.status).toBe(404);
  });

  it("returns 400 on missing fields", async () => {
    const resp = await SELF.fetch("https://worker.test/v2/device/assert", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "1.2.3.8" },
      body: JSON.stringify({ deviceId: "abc-12345678" }),
    });
    expect(resp.status).toBe(400);
  });
});

describe("transition path — X-API-Key still works", () => {
  it("/v2/device/register accepts X-API-Key as before", async () => {
    const resp = await SELF.fetch("https://worker.test/v2/device/register", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": API_KEY,
        "CF-Connecting-IP": "1.2.3.9",
      },
      body: JSON.stringify({ deviceId: "abc-12345678", pushToken: "deadbeef", platform: "ios" }),
    });
    expect(resp.status).toBe(200);
    const body = await resp.json() as { ok?: boolean };
    expect(body.ok).toBe(true);
  });
});
