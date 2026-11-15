import { SELF, env } from "cloudflare:test";
import { describe, it, expect, afterEach } from "vitest";

const BASE = "https://example.com";

async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function leadingZeroBits(hash: Uint8Array): number {
  let bits = 0;
  for (const byte of hash) {
    if (byte === 0) { bits += 8; continue; }
    bits += Math.clz32(byte) - 24;
    break;
  }
  return bits;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) { out.set(part, offset); offset += part.length; }
  return out;
}

function beUint64(n: number): Uint8Array {
  const out = new Uint8Array(8);
  new DataView(out.buffer).setBigUint64(0, BigInt(n), false);
  return out;
}

/** Mirrors the shipped client: sha256(utf8(challenge) || proofBE8) with 16 leading zero bits. */
async function mineLegacy(challenge: string): Promise<number> {
  const prefix = new TextEncoder().encode(challenge);
  for (let proof = 0; proof < 5_000_000; proof++) {
    if (leadingZeroBits(await sha256(concat(prefix, beUint64(proof)))) >= 16) return proof;
  }
  throw new Error("legacy mining failed");
}

/** sha256(challenge || mailboxId || sha256(ciphertext) || proofBE8). */
async function mineBound(challenge: string, mailboxId: string, ciphertext: string, difficulty: number): Promise<number> {
  const enc = new TextEncoder();
  const prefix = concat(enc.encode(challenge), enc.encode(mailboxId), await sha256(enc.encode(ciphertext)));
  for (let proof = 0; proof < 5_000_000; proof++) {
    if (leadingZeroBits(await sha256(concat(prefix, beUint64(proof)))) >= difficulty) return proof;
  }
  throw new Error("bound mining failed");
}

async function issueChallenge(mailboxId: string): Promise<{ challenge: string; difficulty: number }> {
  const resp = await SELF.fetch(`${BASE}/v2/messages/${mailboxId}/challenge`, { method: "POST" });
  expect(resp.status).toBe(201);
  const body = (await resp.json()) as { challenge: string; difficulty: number; expiresInSeconds: number };
  expect(body.difficulty).toBe(8);
  expect(body.expiresInSeconds).toBe(300);
  return body;
}

function deliver(mailboxId: string, ciphertext: string, challenge: string, proof: number): Promise<Response> {
  return SELF.fetch(`${BASE}/v2/messages/${mailboxId}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ciphertext, pow: { challenge, proof } }),
  });
}

async function legacyCountToday(): Promise<number> {
  return parseInt((await env.V2_STORE.get(`pow-legacy:${new Date().toISOString().slice(0, 10)}`)) ?? "0");
}

describe("mailbox PoW: server-issued, single-use, content-bound", () => {
  it("accepts a proof bound to the issued challenge, mailbox and ciphertext", async () => {
    const { challenge, difficulty } = await issueChallenge("bound01");
    const proof = await mineBound(challenge, "bound01", "ct-happy", difficulty);
    expect((await deliver("bound01", "ct-happy", challenge, proof)).status).toBe(201);
  });

  it("rejects a second delivery with the same challenge and proof", async () => {
    const { challenge, difficulty } = await issueChallenge("replay01");
    const proof = await mineBound(challenge, "replay01", "ct-replay", difficulty);
    expect((await deliver("replay01", "ct-replay", challenge, proof)).status).toBe(201);
    expect((await deliver("replay01", "ct-replay", challenge, proof)).status).toBe(403);
  });

  it("rejects a proof mined for a different ciphertext", async () => {
    const { challenge, difficulty } = await issueChallenge("swap01");
    const proof = await mineBound(challenge, "swap01", "ct-original", difficulty);
    expect((await deliver("swap01", "ct-swapped", challenge, proof)).status).toBe(403);
  });

  it("rejects a challenge issued for another mailbox", async () => {
    const { challenge, difficulty } = await issueChallenge("mbxa01");
    const proof = await mineBound(challenge, "mbxb01", "ct-cross", difficulty);
    expect((await deliver("mbxb01", "ct-cross", challenge, proof)).status).toBe(403);
  });

  it("burns the challenge when the proof is wrong", async () => {
    const { challenge, difficulty } = await issueChallenge("burn01");
    const good = await mineBound(challenge, "burn01", "ct-burn", difficulty);
    expect((await deliver("burn01", "ct-burn", challenge, good + 1)).status).toBe(403);
    expect((await deliver("burn01", "ct-burn", challenge, good)).status).toBe(403);
  });

  it("does not count bound deliveries as legacy", async () => {
    const before = await legacyCountToday();
    const { challenge, difficulty } = await issueChallenge("nolegacy01");
    const proof = await mineBound(challenge, "nolegacy01", "ct-count", difficulty);
    expect((await deliver("nolegacy01", "ct-count", challenge, proof)).status).toBe(201);
    expect(await legacyCountToday()).toBe(before);
  });
});

describe("mailbox PoW: legacy client-chosen challenge (shipped clients)", () => {
  const original = (env as { POW_LEGACY?: string }).POW_LEGACY;
  afterEach(() => { (env as { POW_LEGACY?: string }).POW_LEGACY = original; });

  it("still accepts the old format and counts it", async () => {
    const before = await legacyCountToday();
    const challenge = crypto.randomUUID();
    const proof = await mineLegacy(challenge);
    expect((await deliver("legacy01", "ct-legacy", challenge, proof)).status).toBe(201);
    expect(await legacyCountToday()).toBe(before + 1);
  });

  it("rejects a legacy proof that does not meet the difficulty", async () => {
    expect((await deliver("legacy02", "ct-bad", crypto.randomUUID(), 0)).status).toBe(403);
  });

  it("rejects the old format once POW_LEGACY is off", async () => {
    (env as { POW_LEGACY?: string }).POW_LEGACY = "off";
    const challenge = crypto.randomUUID();
    const proof = await mineLegacy(challenge);
    expect((await deliver("legacy03", "ct-off", challenge, proof)).status).toBe(403);
  });

  it("still accepts bound proofs once POW_LEGACY is off", async () => {
    (env as { POW_LEGACY?: string }).POW_LEGACY = "off";
    const { challenge, difficulty } = await issueChallenge("legacy04");
    const proof = await mineBound(challenge, "legacy04", "ct-still", difficulty);
    expect((await deliver("legacy04", "ct-still", challenge, proof)).status).toBe(201);
  });
});

describe("mailbox PoW: malformed bodies", () => {
  it("answers 400 for missing or mistyped fields", async () => {
    const send = (body: unknown) => SELF.fetch(`${BASE}/v2/messages/bad01`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    expect((await send({})).status).toBe(400);
    expect((await send({ ciphertext: "x" })).status).toBe(400);
    expect((await send({ ciphertext: "x", pow: { challenge: 1, proof: 1 } })).status).toBe(400);
    expect((await send({ ciphertext: "x", pow: { challenge: "c", proof: "1" } })).status).toBe(400);
    expect((await SELF.fetch(`${BASE}/v2/messages/bad01`, { method: "POST", body: "not json" })).status).toBe(400);
  });
});
