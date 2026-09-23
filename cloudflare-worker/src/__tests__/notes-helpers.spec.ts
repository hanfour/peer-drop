import { env } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { NOTE_LIMITS, ulid, senderHash, notePoWMessage, parseEnvelope } from "../notes";
import { verifyPoW } from "../pow";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

const b64 = (n: number, fill = 7) => btoa(String.fromCharCode(...new Uint8Array(n).fill(fill)));
function envelopeJson(overrides: Record<string, unknown> = {}): string {
  const obj = { v: 1, ephemeralKey: b64(32), ephemeralKey2: b64(32, 9), spkId: 3, opkId: 11, nonce: b64(12), ciphertext: b64(40), ...overrides };
  return btoa(JSON.stringify(obj));
}

describe("notes helpers", () => {
  it("ulid is 26 Crockford chars and sorts by time", () => {
    const a = ulid(1_700_000_000_000), b = ulid(1_700_000_001_000);
    expect(a).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(a.slice(0, 10) < b.slice(0, 10)).toBe(true);
    expect(ulid()).not.toBe(ulid());
  });
  it("senderHash is a deterministic 64-hex HMAC that differs per account and per secret", async () => {
    const h1 = await senderHash("s1", "ACCT0001"), h2 = await senderHash("s1", "ACCT0001");
    expect(h1).toMatch(/^[0-9a-f]{64}$/);
    expect(h1).toBe(h2);
    expect(await senderHash("s1", "ACCT0002")).not.toBe(h1);
    expect(await senderHash("s2", "ACCT0001")).not.toBe(h1);
  });
  it("notePoWMessage binds challenge, recipient and the envelope digest", async () => {
    const msg = await notePoWMessage("CHAL", "ACCT0001", new TextEncoder().encode("abc"));
    expect(msg).toBe("CHAL|ACCT0001|ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });
  it("parseEnvelope accepts a well-formed envelope and rejects malformed ones", () => {
    const ok = parseEnvelope(envelopeJson());
    expect(ok.ok).toBe(true);
    expect(parseEnvelope(envelopeJson({ opkId: undefined })).ok).toBe(true);
    expect(parseEnvelope("%%%not-base64")).toEqual({ ok: false, error: "invalid_envelope" });
    expect(parseEnvelope(btoa("{\"v\":2}"))).toEqual({ ok: false, error: "invalid_envelope" });
    expect(parseEnvelope(envelopeJson({ ephemeralKey: b64(31) }))).toEqual({ ok: false, error: "invalid_envelope" });
    expect(parseEnvelope(envelopeJson({ nonce: b64(11) }))).toEqual({ ok: false, error: "invalid_envelope" });
    expect(parseEnvelope(envelopeJson({ ciphertext: b64(15) }))).toEqual({ ok: false, error: "invalid_envelope" });
    expect(parseEnvelope(envelopeJson({ spkId: "3" }))).toEqual({ ok: false, error: "invalid_envelope" });
    expect(parseEnvelope(envelopeJson({ ciphertext: b64(NOTE_LIMITS.envelopeMaxBytes) }))).toEqual({ ok: false, error: "too_large" });
  });
  it("verifyPoW still verifies after the move", async () => {
    // difficulty 8: brute-force a nonce here so the test stays fast.
    let nonce = 0;
    while (!(await verifyPoW("moved", nonce, 8))) nonce++;
    expect(await verifyPoW("moved", nonce, 8)).toBe(true);
    expect(await verifyPoW("moved", nonce + 1_000_003, 8)).toBe(false);
  });
  it("0002 migration creates blocks and reports", async () => {
    await env.ACCOUNTS_DB.prepare("INSERT INTO blocks (account_id, sender_hash, created_at) VALUES ('A', 'h', 1)").run();
    await env.ACCOUNTS_DB.prepare("INSERT INTO reports (id, reporter_account_id, sender_hash, inbox_item_id, reason, excerpt, created_at) VALUES ('r1','A','h','i','spam',NULL,1)").run();
    expect((await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM blocks").first<{ n: number }>())?.n).toBe(1);
    expect((await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM reports").first<{ n: number }>())?.n).toBe(1);
  });
});
