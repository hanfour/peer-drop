// Recomputes test-vectors/group-crypto.json inside workerd, layer by layer:
// groupSig.ts's memberKeyMessage / wrapMessage must give the exact message
// bytes, both signatures must verify through verifyAccountSig (the server's
// own check, against a D1 accounts.signing_key row), and the client-side
// layers (X25519 → HKDF wrap key → AES-GCM wrap, message / metaCipher AAD and
// AES-GCM) must reproduce the generator's output. G1b's Swift GroupCrypto
// tests consume the same file.
import { env } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import vectors from "../../test-vectors/group-crypto.json";
import { memberKeyMessage, wrapMessage, verifyAccountSig, decodeB64 } from "../groupSig";

const fromHex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const toHex = (u: Uint8Array): string => Array.from(u).map((b) => b.toString(16).padStart(2, "0")).join("");
const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);
const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};
const u32be = (n: number): Uint8Array => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, false); return b; };
const PKCS8_X25519 = fromHex("302e020100300506032b656e04220420");
/** X25519 deriveBits params (workers-types names the field `$public`; WebCrypto wants `public`). */
const x25519Params = (pub: CryptoKey) => ({ name: "X25519", public: pub }) as unknown as SubtleCryptoDeriveKeyAlgorithm;

async function aesGcmOpen(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array, sealed: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", key, { name: "AES-GCM" }, false, ["decrypt"]);
  return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce, additionalData: aad, tagLength: 128 }, k, sealed));
}
async function aesGcmSeal(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array, pt: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", key, { name: "AES-GCM" }, false, ["encrypt"]);
  return new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad, tagLength: 128 }, k, pt));
}

beforeAll(async () => {
  await applyMigrations(env.ACCOUNTS_DB);
  // The vector's account, with the vector's Ed25519 public key as its signing key.
  await env.ACCOUNTS_DB.prepare(
    "INSERT OR REPLACE INTO accounts (account_id, signing_key, identity_key, mailbox_id, created_at, updated_at) VALUES (?1, ?2, ?3, 'mbx-group-vectors', 1, 1)",
  ).bind(vectors.inputs.accountId, fromHex(vectors.signing.publicKeyHex), new Uint8Array(32).fill(0xee)).run();
});

describe("group-crypto.json", () => {
  it("group-crypto.json vectors recompute in workerd", async () => {
    const v = vectors;
    // ---- memberKeySig: message bytes + server-side verification
    const mk = v.memberKeySig;
    const mkMsg = memberKeyMessage(mk.groupId, mk.memberId, mk.accountId, fromHex(mk.pubKeyHex));
    expect(toHex(mkMsg)).toBe(mk.messageHex);
    expect(mkMsg.length).toBe(100);
    expect(toHex(decodeB64(mk.pubKeyB64)!)).toBe(mk.pubKeyHex);
    expect(toHex(decodeB64(mk.signatureB64)!)).toBe(mk.signatureHex);
    expect(await verifyAccountSig(env.ACCOUNTS_DB, mk.accountId, mkMsg, mk.signatureB64)).toBe(true);
    // a one-byte change no longer verifies
    const mkBad = mkMsg.slice(); mkBad[mkBad.length - 1] ^= 1;
    expect(await verifyAccountSig(env.ACCOUNTS_DB, mk.accountId, mkBad, mk.signatureB64)).toBe(false);
    // the member's room pubKey really is the X25519 public key of the given private key (checked below with deriveBits too)

    // ---- wrap: AAD, salt, wrap key, sealed room key
    const w = v.wrap;
    const aad = concat(utf8(w.groupId), u32be(w.epoch), utf8(w.memberId));
    expect(toHex(aad)).toBe(w.aadHex);
    const ephPub = fromHex(w.ephemeralPublicKeyHex), recPub = fromHex(w.recipientPublicKeyHex);
    expect(toHex(concat(ephPub, recPub))).toBe(w.hkdfSaltHex);
    // X25519 layer: workerd imports an X25519 private key from PKCS#8.
    // (If a future workerd stops supporting that, fall back to trusting the
    // generator's sharedSecretHex for this one layer and keep the rest.)
    const recPriv = await crypto.subtle.importKey("pkcs8", concat(PKCS8_X25519, fromHex(w.recipientPrivateKeyHex)), { name: "X25519" }, false, ["deriveBits"]);
    const ephPubKey = await crypto.subtle.importKey("raw", ephPub, { name: "X25519" }, false, []);
    const shared = new Uint8Array(await crypto.subtle.deriveBits(x25519Params(ephPubKey), recPriv, 256));
    expect(toHex(shared)).toBe(w.sharedSecretHex);
    // and the sender's side gives the same secret
    const ephPriv = await crypto.subtle.importKey("pkcs8", concat(PKCS8_X25519, fromHex(w.ephemeralPrivateKeyHex)), { name: "X25519" }, false, ["deriveBits"]);
    const recPubKey = await crypto.subtle.importKey("raw", recPub, { name: "X25519" }, false, []);
    expect(toHex(new Uint8Array(await crypto.subtle.deriveBits(x25519Params(recPubKey), ephPriv, 256)))).toBe(w.sharedSecretHex);
    const ikm = await crypto.subtle.importKey("raw", fromHex(w.sharedSecretHex), "HKDF", false, ["deriveBits"]);
    const wrapKey = new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: concat(ephPub, recPub), info: utf8(w.hkdfInfo) }, ikm, 256));
    expect(w.hkdfInfo).toBe("peerdrop-group-wrap-v1");
    expect(toHex(wrapKey)).toBe(w.wrapKeyHex);
    const wrapped = fromHex(w.wrappedHex);
    expect(wrapped.length).toBe(92);
    expect(toHex(decodeB64(w.wrappedB64)!)).toBe(w.wrappedHex);
    expect(toHex(wrapped.subarray(0, 32))).toBe(w.ephemeralPublicKeyHex);
    expect(toHex(wrapped.subarray(32, 44))).toBe(w.nonceHex);
    const roomKey = await aesGcmOpen(wrapKey, wrapped.subarray(32, 44), aad, wrapped.subarray(44));
    expect(toHex(roomKey)).toBe(w.roomKeyHex);
    expect(toHex(concat(ephPub, fromHex(w.nonceHex), await aesGcmSeal(wrapKey, fromHex(w.nonceHex), aad, roomKey)))).toBe(w.wrappedHex);

    // ---- wrapSig: message bytes + server-side verification
    const ws = v.wrapSig;
    expect(ws.wrappedB64).toBe(w.wrappedB64);
    const wsMsg = wrapMessage(ws.groupId, ws.epoch, ws.targetMemberId, ws.wrapperMemberId, decodeB64(ws.wrappedB64)!);
    expect(toHex(wsMsg)).toBe(ws.messageHex);
    expect(wsMsg.length).toBe(182);
    expect(await verifyAccountSig(env.ACCOUNTS_DB, v.inputs.accountId, wsMsg, ws.signatureB64)).toBe(true);
    // swapping target and wrapper (or the epoch) breaks it
    expect(await verifyAccountSig(env.ACCOUNTS_DB, v.inputs.accountId, wrapMessage(ws.groupId, ws.epoch, ws.wrapperMemberId, ws.targetMemberId, decodeB64(ws.wrappedB64)!), ws.signatureB64)).toBe(false);
    expect(await verifyAccountSig(env.ACCOUNTS_DB, v.inputs.accountId, wrapMessage(ws.groupId, ws.epoch + 1, ws.targetMemberId, ws.wrapperMemberId, decodeB64(ws.wrappedB64)!), ws.signatureB64)).toBe(false);
    // the two signed formats are domain-separated: a member-key signature never passes as a wrap signature
    expect(await verifyAccountSig(env.ACCOUNTS_DB, v.inputs.accountId, wsMsg, mk.signatureB64)).toBe(false);

    // ---- message
    const m = v.message;
    const mAad = concat(utf8(m.groupId), utf8(m.memberId), utf8(m.eventId), u32be(m.epoch));
    expect(toHex(mAad)).toBe(m.aadHex);
    const payload = decodeB64(m.payloadCipherB64)!;
    expect(toHex(payload.subarray(0, 12))).toBe(m.nonceHex);
    expect(new TextDecoder().decode(await aesGcmOpen(fromHex(m.roomKeyHex), payload.subarray(0, 12), mAad, payload.subarray(12)))).toBe(m.plaintext);
    expect(m.roomKeyHex).toBe(w.roomKeyHex);

    // ---- metaCipher
    const mc = v.metaCipher;
    const mcAad = concat(utf8(mc.groupId), u32be(mc.epoch), utf8("meta"));
    expect(toHex(mcAad)).toBe(mc.aadHex);
    const meta = decodeB64(mc.metaCipherB64)!;
    expect(toHex(meta.subarray(0, 12))).toBe(mc.nonceHex);
    expect(new TextDecoder().decode(await aesGcmOpen(fromHex(mc.roomKeyHex), meta.subarray(0, 12), mcAad, meta.subarray(12)))).toBe(mc.plaintext);
  });
});
