import { describe, it, expect } from "vitest";
import { matchRpIdHash } from "../appAttest";
import { configuredBundleIds } from "../index";

async function sha256(s: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
}

describe("App Attest bundle set", () => {
  it("configuredBundleIds defaults to iOS + Mac and merges legacy APP_BUNDLE_ID", () => {
    expect(configuredBundleIds({})).toEqual(["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"]);
    expect(configuredBundleIds({ APP_BUNDLE_IDS: "a.b, c.d" })).toEqual(["a.b", "c.d"]);
    expect(configuredBundleIds({ APP_BUNDLE_IDS: "a.b", APP_BUNDLE_ID: "legacy.id" })).toEqual(["a.b", "legacy.id"]);
  });

  it("matchRpIdHash returns the matching bundle id or null", async () => {
    const mac = await sha256("UK48R5KWLV.com.hanfour.peerdrop.mac");
    expect(await matchRpIdHash(mac, "UK48R5KWLV", ["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"])).toBe("com.hanfour.peerdrop.mac");
    const other = await sha256("UK48R5KWLV.com.example.other");
    expect(await matchRpIdHash(other, "UK48R5KWLV", ["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"])).toBeNull();
  });
});
