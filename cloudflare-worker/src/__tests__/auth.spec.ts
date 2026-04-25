/**
 * API-key authentication — coverage for the `requiresAuth` list in
 * src/index.ts (POST /room, POST /room/:code/ice, POST /v2/device/register,
 * POST /v2/invite/:deviceId, WS /v2/inbox/:deviceId).
 *
 * These tests pin the contract for clients: missing or wrong key → 401;
 * correct key → success. Regression guard against any future refactor of the
 * auth middleware that accidentally drops one of these endpoints from the list.
 */

import { SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";

const API_KEY = "test-api-key-12345";
const WRONG_KEY = "definitely-wrong-key";

interface CreatedRoom {
  roomCode: string;
  roomToken: string;
}

async function createRoom(): Promise<CreatedRoom> {
  const resp = await SELF.fetch("https://example.com/room", {
    method: "POST",
    headers: { "X-API-Key": API_KEY },
  });
  expect(resp.status).toBe(201);
  return (await resp.json()) as CreatedRoom;
}

// --------------------------------------------------------------------------
// POST /room
// --------------------------------------------------------------------------

describe("auth — POST /room", () => {
  it("returns 401 with no API key", async () => {
    const resp = await SELF.fetch("https://example.com/room", { method: "POST" });
    expect(resp.status).toBe(401);
    const body = (await resp.json()) as { error: string };
    expect(body.error).toBe("Unauthorized");
  });

  it("returns 401 with wrong API key", async () => {
    const resp = await SELF.fetch("https://example.com/room", {
      method: "POST",
      headers: { "X-API-Key": WRONG_KEY },
    });
    expect(resp.status).toBe(401);
  });

  it("returns 201 with correct API key and a roomCode + roomToken", async () => {
    const resp = await SELF.fetch("https://example.com/room", {
      method: "POST",
      headers: { "X-API-Key": API_KEY },
    });
    expect(resp.status).toBe(201);
    const body = (await resp.json()) as CreatedRoom;
    expect(body.roomCode).toMatch(/^[A-Z0-9]{6}$/);
    expect(body.roomToken).toMatch(/^[0-9a-f]{32}$/);
  });
});

// --------------------------------------------------------------------------
// POST /room/:code/ice
// --------------------------------------------------------------------------

describe("auth — POST /room/:code/ice", () => {
  it("returns 401 with no API key", async () => {
    const { roomCode } = await createRoom();
    const resp = await SELF.fetch(`https://example.com/room/${roomCode}/ice`, {
      method: "POST",
    });
    expect(resp.status).toBe(401);
  });

  it("returns 200 with correct API key (STUN-only fallback when TURN unset)", async () => {
    const { roomCode } = await createRoom();
    const resp = await SELF.fetch(`https://example.com/room/${roomCode}/ice`, {
      method: "POST",
      headers: { "X-API-Key": API_KEY },
    });
    // TURN_KEY_ID/TURN_API_TOKEN are empty in the test env, so we get the
    // STUN-only fallback path — still a 200 with iceServers + roomToken.
    expect(resp.status).toBe(200);
    const body = (await resp.json()) as { iceServers: unknown[]; roomToken: string };
    expect(Array.isArray(body.iceServers)).toBe(true);
    expect(body.roomToken).toMatch(/^[0-9a-f]{32}$/);
  });
});

// --------------------------------------------------------------------------
// POST /v2/device/register
// --------------------------------------------------------------------------

describe("auth — POST /v2/device/register", () => {
  it("returns 401 with no API key", async () => {
    const resp = await SELF.fetch("https://example.com/v2/device/register", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ deviceId: "device-test-1234", pushToken: "abc" }),
    });
    expect(resp.status).toBe(401);
  });

  it("returns 200 with correct API key + valid body", async () => {
    const resp = await SELF.fetch("https://example.com/v2/device/register", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": API_KEY },
      body: JSON.stringify({ deviceId: "device-test-1234", pushToken: "abc" }),
    });
    expect(resp.status).toBe(200);
    const body = (await resp.json()) as { ok: boolean };
    expect(body.ok).toBe(true);
  });
});

// --------------------------------------------------------------------------
// POST /v2/invite/:deviceId
// --------------------------------------------------------------------------

describe("auth — POST /v2/invite/:deviceId", () => {
  it("returns 401 with no API key", async () => {
    const resp = await SELF.fetch("https://example.com/v2/invite/device-test-1234", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ roomCode: "ABCDEF", roomToken: "x", senderName: "Alice" }),
    });
    expect(resp.status).toBe(401);
  });
});

// --------------------------------------------------------------------------
// WS /v2/inbox/:deviceId
// --------------------------------------------------------------------------

describe("auth — WS /v2/inbox/:deviceId", () => {
  it("returns 401 on upgrade without apiKey query param", async () => {
    const resp = await SELF.fetch(
      "https://example.com/v2/inbox/device-test-1234",
      { headers: { Upgrade: "websocket" } },
    );
    expect(resp.status).toBe(401);
  });

  it("returns 101 on upgrade with correct apiKey query param", async () => {
    const resp = await SELF.fetch(
      `https://example.com/v2/inbox/device-test-1234?apiKey=${API_KEY}`,
      { headers: { Upgrade: "websocket" } },
    );
    expect(resp.status).toBe(101);
    expect(resp.webSocket).toBeDefined();
    resp.webSocket!.accept();
    resp.webSocket!.close();
  });

  it("returns 401 on upgrade with wrong apiKey query param", async () => {
    const resp = await SELF.fetch(
      `https://example.com/v2/inbox/device-test-1234?apiKey=${WRONG_KEY}`,
      { headers: { Upgrade: "websocket" } },
    );
    expect(resp.status).toBe(401);
  });
});
