/**
 * SignalingRoom Durable Object — miniflare integration tests.
 *
 * Regression guards for:
 *   - v3.2.2: clientId-dedup eviction on reconnect
 *   - v3.3.1: zombie eviction (stale sockets >60s old freed when room appears full)
 *   - General capacity + token validation
 *
 * The v3.3.0 production incident (zombie sockets accumulating in the DO) was
 * directly traceable to ZERO test coverage of the DO. These tests run inside
 * miniflare via @cloudflare/vitest-pool-workers, so they exercise the real
 * Durable Object code path.
 */

import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";

const API_KEY = "test-api-key-12345";

interface CreatedRoom {
  roomCode: string;
  roomToken: string;
}

async function createRoom(): Promise<CreatedRoom> {
  const resp = await SELF.fetch("https://example.com/room", {
    method: "POST",
    headers: { "X-API-Key": API_KEY },
  });
  // POST /room returns 201 Created
  expect(resp.status).toBe(201);
  return (await resp.json()) as CreatedRoom;
}

async function attemptWSUpgrade(
  roomCode: string,
  token: string,
  clientId: string,
): Promise<Response> {
  return await SELF.fetch(
    `https://example.com/room/${roomCode}?clientId=${clientId}&token=${token}`,
    { headers: { Upgrade: "websocket" } },
  );
}

// --------------------------------------------------------------------------
// Capacity + token validation
// --------------------------------------------------------------------------

describe("SignalingRoom — capacity + token validation", () => {
  it("returns 404 when room does not exist", async () => {
    const resp = await SELF.fetch(
      "https://example.com/room/ZZZZZZ?clientId=foo&token=bar",
      { headers: { Upgrade: "websocket" } },
    );
    expect(resp.status).toBe(404);
  });

  it("returns 403 when room token is wrong", async () => {
    const { roomCode } = await createRoom();
    const resp = await attemptWSUpgrade(roomCode, "wrong-token", "client-A");
    expect(resp.status).toBe(403);
  });

  it("returns 403 when token is missing entirely", async () => {
    const { roomCode } = await createRoom();
    const resp = await SELF.fetch(
      `https://example.com/room/${roomCode}?clientId=client-A`,
      { headers: { Upgrade: "websocket" } },
    );
    expect(resp.status).toBe(403);
  });

  it("accepts the first two valid joiners (101)", async () => {
    const { roomCode, roomToken } = await createRoom();
    const a = await attemptWSUpgrade(roomCode, roomToken, "client-A");
    expect(a.status).toBe(101);
    expect(a.webSocket).toBeDefined();
    a.webSocket!.accept();

    const b = await attemptWSUpgrade(roomCode, roomToken, "client-B");
    expect(b.status).toBe(101);
    expect(b.webSocket).toBeDefined();
    b.webSocket!.accept();
  });

  it("rejects a third recent joiner with 409", async () => {
    const { roomCode, roomToken } = await createRoom();

    const a = await attemptWSUpgrade(roomCode, roomToken, "client-A");
    expect(a.status).toBe(101);
    a.webSocket!.accept();

    const b = await attemptWSUpgrade(roomCode, roomToken, "client-B");
    expect(b.status).toBe(101);
    b.webSocket!.accept();

    const c = await attemptWSUpgrade(roomCode, roomToken, "client-C");
    expect(c.status).toBe(409);

    const body = (await c.json()) as { error: string; activeSocketCount: number };
    expect(body.error).toBe("Room is full");
    expect(body.activeSocketCount).toBe(2);
  });
});

// --------------------------------------------------------------------------
// clientId dedup (v3.2.2 regression guard)
// --------------------------------------------------------------------------

describe("SignalingRoom — clientId dedup (v3.2.2 regression guard)", () => {
  it("evicts a prior socket from the same clientId on reconnect", async () => {
    const { roomCode, roomToken } = await createRoom();

    const first = await attemptWSUpgrade(roomCode, roomToken, "client-X");
    expect(first.status).toBe(101);
    first.webSocket!.accept();

    // Same clientId reconnects — should succeed (old socket evicted).
    const reconnect = await attemptWSUpgrade(roomCode, roomToken, "client-X");
    expect(reconnect.status).toBe(101);
    reconnect.webSocket!.accept();

    // Now a new clientId can still join because reconnect evicted the original.
    // Without dedup, this would 409 (room would have client-X[old] + client-X[new] = 2 active).
    const other = await attemptWSUpgrade(roomCode, roomToken, "client-Y");
    expect(other.status).toBe(101);
    other.webSocket!.accept();
  });
});

// --------------------------------------------------------------------------
// Zombie eviction (v3.3.1 regression guard)
//
// Strategy: rather than mutating production code to inject a clock, we use
// `runInDurableObject` to reach into the live DO instance and rewrite each
// WebSocket's serialized attachment so its `createdAt` is far in the past.
// On the next upgrade attempt, the >60s stale-eviction path should fire and
// admit the new joiner instead of returning 409 forever.
// --------------------------------------------------------------------------

describe("SignalingRoom — zombie eviction (v3.3.1 regression guard)", () => {
  it("evicts >60s-old zombie sockets when room appears full", async () => {
    const { roomCode, roomToken } = await createRoom();

    // Fill room with two "real" peers.
    const a = await attemptWSUpgrade(roomCode, roomToken, "zombie-A");
    expect(a.status).toBe(101);
    a.webSocket!.accept();

    const b = await attemptWSUpgrade(roomCode, roomToken, "zombie-B");
    expect(b.status).toBe(101);
    b.webSocket!.accept();

    // Sanity: a 3rd peer is rejected as expected.
    const cBeforeStale = await attemptWSUpgrade(
      roomCode,
      roomToken,
      "fresh-C",
    );
    expect(cBeforeStale.status).toBe(409);

    // Reach into the DO and rewrite createdAt to be 2 minutes in the past
    // — simulating sockets that leaked from a prior session (zombies).
    const id = env.SIGNALING_ROOM.idFromName(roomCode);
    const stub = env.SIGNALING_ROOM.get(id);
    await runInDurableObject(stub, async (_instance, state) => {
      const sockets = state.getWebSockets();
      const ancientTimestamp = Date.now() - 2 * 60 * 1000; // 120s ago
      for (const ws of sockets) {
        const att = ws.deserializeAttachment() as
          | { clientId?: string; createdAt?: number }
          | null;
        ws.serializeAttachment({
          clientId: att?.clientId,
          createdAt: ancientTimestamp,
        });
      }
    });

    // Now a new joiner should succeed: the stale-eviction sweep frees space.
    const cAfterStale = await attemptWSUpgrade(
      roomCode,
      roomToken,
      "fresh-C",
    );
    expect(cAfterStale.status).toBe(101);
    cAfterStale.webSocket!.accept();
  });

  it("evicts sockets whose underlying connection is dead (probe path)", async () => {
    const { roomCode, roomToken } = await createRoom();

    // Two joiners, then accept + immediately close the client side so the
    // server-side ws.send(ping) will throw on the next probe.
    const a = await attemptWSUpgrade(roomCode, roomToken, "probe-A");
    expect(a.status).toBe(101);
    a.webSocket!.accept();
    a.webSocket!.close();

    const b = await attemptWSUpgrade(roomCode, roomToken, "probe-B");
    expect(b.status).toBe(101);
    b.webSocket!.accept();
    b.webSocket!.close();

    // Give the runtime a tick to register the close on the server side via
    // the hibernation API, otherwise the sockets are still in readyState 1.
    // We don't strictly need them to be in readyState 1 for the eviction
    // path — but if the server's send() now throws, that's the probe path.
    await new Promise<void>((resolve) => setTimeout(resolve, 50));

    // A 3rd joiner should be admitted: either via the probe path
    // (send-throws → stale) or via the natural close-handler path.
    const c = await attemptWSUpgrade(roomCode, roomToken, "probe-C");
    expect(c.status).toBe(101);
    c.webSocket!.accept();
  });
});
