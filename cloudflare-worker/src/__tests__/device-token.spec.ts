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
import { encode as cborEncode } from "cbor2";
import { issueToken, verifyToken, freshTokenPayload } from "../deviceToken";
import { verifyAssertion } from "../appAttest";

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

describe("/v2/device/attest (real verifier)", () => {
  // /v2/device/attest pulls a server-issued challenge from V2_STORE
  // (set by /v2/device/challenge). Tests that exercise the verifier
  // must first request a challenge so the replay-defense check passes
  // and the verifier itself is what rejects the garbage.
  async function issueChallenge(deviceId: string, ip: string): Promise<string> {
    const resp = await SELF.fetch("https://worker.test/v2/device/challenge", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": ip },
      body: JSON.stringify({ deviceId }),
    });
    expect(resp.status).toBe(201);
    const body = await resp.json() as { challenge: string };
    return body.challenge;
  }

  it("returns 400 with CBOR decode error on garbage attestation bytes", async () => {
    const deviceId = "abc-12345678";
    const challenge = await issueChallenge(deviceId, "1.2.3.4");
    const resp = await SELF.fetch("https://worker.test/v2/device/attest", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "1.2.3.4" },
      body: JSON.stringify({
        deviceId,
        attestation: btoa("fake-cbor-blob"),
        keyId: btoa("fake-key-id"),
        challenge,
      }),
    });
    expect(resp.status).toBe(400);
    const body = await resp.json() as { error?: string };
    expect(body.error?.toLowerCase()).toMatch(/cbor|decode|attestation/);
  });

  it("returns 400 when challenge wasn't issued first", async () => {
    const resp = await SELF.fetch("https://worker.test/v2/device/attest", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "1.2.3.10" },
      body: JSON.stringify({
        deviceId: "no-challenge-device",
        attestation: btoa("x"),
        keyId: btoa("x"),
        challenge: btoa("never-stored"),
      }),
    });
    expect(resp.status).toBe(400);
    const body = await resp.json() as { error?: string };
    expect(body.error?.toLowerCase()).toMatch(/challenge/);
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

describe("verifyAssertion (full round-trip with synthetic keypair)", () => {
  // Synthesize a real ECDSA P-256 keypair, build the assertion shape
  // Apple's framework produces, sign it ourselves, and let the verifier
  // chew on it. Pins the assertion math end-to-end without needing a
  // real iOS device.

  const BUNDLE_ID = "com.hanfour.peerdrop";
  const TEAM_ID = "UK48R5KWLV";

  async function rpIdHash(): Promise<Uint8Array> {
    return new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${TEAM_ID}.${BUNDLE_ID}`)),
    );
  }

  function buildAuthData(rpHash: Uint8Array, counter: number): Uint8Array {
    // 32 + 1 + 4 = 37 bytes for assertion-shaped authData.
    const buf = new Uint8Array(37);
    buf.set(rpHash, 0);
    buf[32] = 0;
    buf[33] = (counter >>> 24) & 0xff;
    buf[34] = (counter >>> 16) & 0xff;
    buf[35] = (counter >>> 8) & 0xff;
    buf[36] = counter & 0xff;
    return buf;
  }

  function rawSigToDer(rawSig: Uint8Array): Uint8Array {
    // Web Crypto returns ECDSA signatures in IEEE 1363 raw r||s (64 bytes
    // for P-256). Apple/CBOR carries DER. Convert.
    const r = rawSig.subarray(0, 32);
    const s = rawSig.subarray(32, 64);
    const encInt = (n: Uint8Array): Uint8Array => {
      // Strip leading zeros, then re-add ONE if the high bit is set
      // (DER INTEGERs are signed, so a high-bit byte needs the 0x00
      // prefix to stay positive).
      let i = 0;
      while (i < n.length - 1 && n[i] === 0) i++;
      let stripped = n.subarray(i);
      if (stripped[0] & 0x80) {
        const padded = new Uint8Array(stripped.length + 1);
        padded.set(stripped, 1);
        stripped = padded;
      }
      const tlv = new Uint8Array(2 + stripped.length);
      tlv[0] = 0x02; tlv[1] = stripped.length; tlv.set(stripped, 2);
      return tlv;
    };
    const rTLV = encInt(r);
    const sTLV = encInt(s);
    const out = new Uint8Array(2 + rTLV.length + sTLV.length);
    out[0] = 0x30; out[1] = rTLV.length + sTLV.length;
    out.set(rTLV, 2);
    out.set(sTLV, 2 + rTLV.length);
    return out;
  }

  async function signAssertion(privateKey: CryptoKey, authData: Uint8Array, clientData: Uint8Array): Promise<Uint8Array> {
    const clientDataHash = new Uint8Array(await crypto.subtle.digest("SHA-256", clientData));
    const composite = new Uint8Array(authData.length + clientDataHash.length);
    composite.set(authData, 0);
    composite.set(clientDataHash, authData.length);
    const nonce = new Uint8Array(await crypto.subtle.digest("SHA-256", composite));
    const rawSig = new Uint8Array(
      await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, nonce),
    );
    return rawSigToDer(rawSig);
  }

  it("accepts a valid synthetic assertion and bumps counter", async () => {
    const kp = (await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
    )) as CryptoKeyPair;
    const pubDer = new Uint8Array(await crypto.subtle.exportKey("spki", kp.publicKey) as ArrayBuffer);

    const authData = buildAuthData(await rpIdHash(), 42);
    const clientData = new TextEncoder().encode("hello-client");
    const sigDer = await signAssertion(kp.privateKey, authData, clientData);

    const cborMap = new Map<string, Uint8Array>([
      ["signature", sigDer],
      ["authenticatorData", authData],
    ]);
    const assertion = cborEncode(cborMap);

    const result = await verifyAssertion({
      assertion,
      clientData,
      publicKeyDer: pubDer,
      previousCounter: 0,
      bundleIdentifier: BUNDLE_ID,
      teamIdentifier: TEAM_ID,
    });
    expect(result.newCounter).toBe(42);
  });

  it("rejects an assertion whose counter has not advanced", async () => {
    const kp = (await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
    )) as CryptoKeyPair;
    const pubDer = new Uint8Array(await crypto.subtle.exportKey("spki", kp.publicKey) as ArrayBuffer);

    const authData = buildAuthData(await rpIdHash(), 5);
    const clientData = new TextEncoder().encode("hi");
    const sigDer = await signAssertion(kp.privateKey, authData, clientData);
    const assertion = cborEncode(new Map<string, Uint8Array>([
      ["signature", sigDer],
      ["authenticatorData", authData],
    ]));

    await expect(verifyAssertion({
      assertion, clientData, publicKeyDer: pubDer, previousCounter: 5,
      bundleIdentifier: BUNDLE_ID, teamIdentifier: TEAM_ID,
    })).rejects.toThrow(/counter/i);
  });

  it("rejects an assertion signed by a different key", async () => {
    const trueKp = (await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
    )) as CryptoKeyPair;
    const otherKp = (await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
    )) as CryptoKeyPair;
    const truePubDer = new Uint8Array(await crypto.subtle.exportKey("spki", trueKp.publicKey) as ArrayBuffer);
    const authData = buildAuthData(await rpIdHash(), 1);
    const clientData = new TextEncoder().encode("h");
    // Sign with the OTHER key but submit the trusted pubkey.
    const sigDer = await signAssertion(otherKp.privateKey, authData, clientData);
    const assertion = cborEncode(new Map<string, Uint8Array>([
      ["signature", sigDer],
      ["authenticatorData", authData],
    ]));
    await expect(verifyAssertion({
      assertion, clientData, publicKeyDer: truePubDer, previousCounter: 0,
      bundleIdentifier: BUNDLE_ID, teamIdentifier: TEAM_ID,
    })).rejects.toThrow(/signature/i);
  });

  it("rejects an assertion whose rpIdHash is for a different app", async () => {
    const kp = (await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
    )) as CryptoKeyPair;
    const pubDer = new Uint8Array(await crypto.subtle.exportKey("spki", kp.publicKey) as ArrayBuffer);
    const fakeRpHash = new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode("ZZZZZZZZZZ.com.evil.app")),
    );
    const authData = buildAuthData(fakeRpHash, 1);
    const clientData = new TextEncoder().encode("h");
    const sigDer = await signAssertion(kp.privateKey, authData, clientData);
    const assertion = cborEncode(new Map<string, Uint8Array>([
      ["signature", sigDer],
      ["authenticatorData", authData],
    ]));
    await expect(verifyAssertion({
      assertion, clientData, publicKeyDer: pubDer, previousCounter: 0,
      bundleIdentifier: BUNDLE_ID, teamIdentifier: TEAM_ID,
    })).rejects.toThrow(/rpIdHash/);
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
