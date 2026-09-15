import { SELF, env } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { matchRpIdHash } from "../appAttest";
import { configuredBundleIds } from "../index";
import { buildSyntheticAssertion, toBase64 } from "./attestHelpers";

async function sha256(s: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
}

describe("App Attest bundle set", () => {
  it("configuredBundleIds defaults to iOS + Mac and merges legacy APP_BUNDLE_ID", () => {
    expect(configuredBundleIds({})).toEqual(["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"]);
    expect(configuredBundleIds({ APP_BUNDLE_IDS: "a.b, c.d" })).toEqual(["a.b", "c.d"]);
    expect(configuredBundleIds({ APP_BUNDLE_IDS: "a.b", APP_BUNDLE_ID: "legacy.id" })).toEqual(["a.b", "legacy.id"]);
    // Minor: dedupe repeated ids (including a legacy id that's already listed).
    expect(configuredBundleIds({ APP_BUNDLE_IDS: "a.b,a.b", APP_BUNDLE_ID: "a.b" })).toEqual(["a.b"]);
    // Minor: an empty/whitespace-only APP_BUNDLE_IDS is treated as unset,
    // not as "no bundle ids configured".
    expect(configuredBundleIds({ APP_BUNDLE_IDS: "   " })).toEqual(["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"]);
  });

  it("matchRpIdHash returns the matching bundle id or null", async () => {
    const mac = await sha256("UK48R5KWLV.com.hanfour.peerdrop.mac");
    expect(await matchRpIdHash(mac, "UK48R5KWLV", ["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"])).toBe("com.hanfour.peerdrop.mac");
    const other = await sha256("UK48R5KWLV.com.example.other");
    expect(await matchRpIdHash(other, "UK48R5KWLV", ["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"])).toBeNull();
  });
});

// Route-level coverage for the security property the unit tests above
// don't exercise: a key attested under one bundle id must not be able to
// assert as the other. `matchRpIdHash` alone can't catch a regression
// where the /v2/device/assert handler ignores the cached `bundleId` and
// always re-widens to the full configured set — these tests seed KV
// directly (bypassing /v2/device/attest) and drive the real route.
describe("/v2/device/assert bundle pinning", () => {
  const TEAM_ID = "UK48R5KWLV";
  const IOS_BUNDLE = "com.hanfour.peerdrop";
  const MAC_BUNDLE = "com.hanfour.peerdrop.mac";

  async function seedAttestedDevice(deviceId: string, publicKeyDer: Uint8Array, bundleId?: string): Promise<void> {
    const record: Record<string, unknown> = {
      keyId: "test-key-id",
      publicKeyDer: toBase64(publicKeyDer),
      receipt: "",
      counter: 0,
      attestedAt: Date.now(),
    };
    if (bundleId) record.bundleId = bundleId;
    await env.V2_STORE.put(`attest:${deviceId}`, JSON.stringify(record));
  }

  async function generateKeypair(): Promise<{ privateKey: CryptoKey; publicKeyDer: Uint8Array }> {
    const kp = (await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
    )) as CryptoKeyPair;
    const publicKeyDer = new Uint8Array(await crypto.subtle.exportKey("spki", kp.publicKey) as ArrayBuffer);
    return { privateKey: kp.privateKey, publicKeyDer };
  }

  async function postAssert(deviceId: string, assertion: Uint8Array, clientData: Uint8Array, ip: string): Promise<Response> {
    return SELF.fetch("https://worker.test/v2/device/assert", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": ip },
      body: JSON.stringify({
        deviceId,
        assertion: toBase64(assertion),
        clientData: toBase64(clientData),
      }),
    });
  }

  it("rejects an assertion built for a different bundle than the one pinned at attest time", async () => {
    const deviceId = "bundle-pin-reject-mac";
    const { privateKey, publicKeyDer } = await generateKeypair();
    await seedAttestedDevice(deviceId, publicKeyDer, IOS_BUNDLE);

    const clientData = new TextEncoder().encode("assert-reject");
    const assertion = await buildSyntheticAssertion({
      teamId: TEAM_ID, bundleId: MAC_BUNDLE, counter: 1, clientData, privateKey,
    });

    const resp = await postAssert(deviceId, assertion, clientData, "9.9.9.1");
    expect(resp.status).toBe(400);
    const body = await resp.json() as { error?: string };
    expect(body.error).toMatch(/rpIdHash/);
  });

  it("accepts an assertion built for the pinned bundle id", async () => {
    const deviceId = "bundle-pin-accept-ios";
    const { privateKey, publicKeyDer } = await generateKeypair();
    await seedAttestedDevice(deviceId, publicKeyDer, IOS_BUNDLE);

    const clientData = new TextEncoder().encode("assert-accept");
    const assertion = await buildSyntheticAssertion({
      teamId: TEAM_ID, bundleId: IOS_BUNDLE, counter: 1, clientData, privateKey,
    });

    const resp = await postAssert(deviceId, assertion, clientData, "9.9.9.2");
    expect(resp.status).toBe(200);
    const body = await resp.json() as { token?: string; expiresInSeconds?: number };
    expect(body.token).toBeTruthy();
    expect(body.expiresInSeconds).toBe(900);
  });

  it("falls back to the configured bundle set for a legacy record with no bundleId", async () => {
    const deviceId = "bundle-pin-legacy-mac";
    const { privateKey, publicKeyDer } = await generateKeypair();
    await seedAttestedDevice(deviceId, publicKeyDer); // no bundleId — pre-migration record

    const clientData = new TextEncoder().encode("assert-legacy");
    const assertion = await buildSyntheticAssertion({
      teamId: TEAM_ID, bundleId: MAC_BUNDLE, counter: 1, clientData, privateKey,
    });

    const resp = await postAssert(deviceId, assertion, clientData, "9.9.9.3");
    expect(resp.status).toBe(200);
    const body = await resp.json() as { token?: string; expiresInSeconds?: number };
    expect(body.token).toBeTruthy();
    expect(body.expiresInSeconds).toBe(900);
  });
});
