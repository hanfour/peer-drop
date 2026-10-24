/**
 * Cross-language interop: the /rv first frame built by the Swift client
 * (RendezvousFirstFrame.build, deterministic inputs) must be accepted by the
 * Worker. The same fixture is asserted byte-for-byte on the Swift side
 * (PeerDropKit/Tests/PeerDropCoreTests/RendezvousFirstFrameTests.swift).
 */
import { describe, it, expect } from "vitest";
import fixture from "../../test-vectors/rendezvous-first-frame.json";
import { verifyRendezvousClaim, parseSessionId, RV_MAX_FRAME_BYTES } from "../rendezvousPow";

describe("rendezvous first frame (Swift fixture)", () => {
  const nowMs = fixture.nowSeconds * 1000;

  it("fits the frame cap and parses to the expected fields", () => {
    expect(new TextEncoder().encode(fixture.frame).length).toBeLessThanOrEqual(RV_MAX_FRAME_BYTES);
    const claim = JSON.parse(fixture.frame);
    expect(claim).toEqual({
      v: 1,
      t: fixture.expected.t,
      pow: { h: fixture.expected.h, n: fixture.expected.n },
      s: fixture.expected.s,
    });
  });

  it("is accepted by verifyRendezvousClaim and parseSessionId", async () => {
    const claim = JSON.parse(fixture.frame);
    expect(await verifyRendezvousClaim(claim, nowMs)).toBe(fixture.expected.t);
    expect(parseSessionId(claim)).toBe(fixture.expected.s);
  });

  it("is rejected outside the hour window (sanity)", async () => {
    const claim = JSON.parse(fixture.frame);
    expect(await verifyRendezvousClaim(claim, nowMs + 2 * 3_600_000)).toBeNull();
  });
});
