#!/usr/bin/env node
// Generates cloudflare-worker/test-vectors/group-crypto.json — the shared
// group-room crypto vectors (G1a server ↔ G1b `GroupCrypto` on Swift).
//
//   node cloudflare-worker/scripts/gen-group-vectors.mjs > cloudflare-worker/test-vectors/group-crypto.json
//
// Node 22+ WebCrypto only, no dependencies. EVERY input is a fixed constant
// below (keys, nonces, ids), and Ed25519 is deterministic, so re-running it
// reproduces the file byte for byte. The signed-message layouts are written
// out here independently of src/groupSig.ts on purpose:
// src/__tests__/group-vectors.spec.ts checks that groupSig.ts's
// memberKeyMessage / wrapMessage produce exactly these bytes.
import { webcrypto as crypto } from "node:crypto";

const subtle = crypto.subtle;
const enc = new TextEncoder();
const utf8 = (s) => enc.encode(s);
const hex = (u8) => Buffer.from(u8).toString("hex");
const fromHex = (h) => new Uint8Array(Buffer.from(h, "hex"));
const b64 = (u8) => Buffer.from(u8).toString("base64");
const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};
const u32be = (n) => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n >>> 0, false); return b; };
/** n bytes start, start+1, … (mod 256) — readable fixed test material. */
const seq = (start, n) => Uint8Array.from({ length: n }, (_, i) => (start + i) & 0xff);

// PKCS#8 wrappers for a raw 32-byte private key (RFC 8410).
const PKCS8_ED25519 = fromHex("302e020100300506032b657004220420");
const PKCS8_X25519 = fromHex("302e020100300506032b656e04220420");

async function ed25519(seed) {
  const priv = await subtle.importKey("pkcs8", concat(PKCS8_ED25519, seed), { name: "Ed25519" }, true, ["sign"]);
  const jwk = await subtle.exportKey("jwk", priv);
  return { priv, pub: new Uint8Array(Buffer.from(jwk.x, "base64url")) };
}
async function x25519(seed) {
  const priv = await subtle.importKey("pkcs8", concat(PKCS8_X25519, seed), { name: "X25519" }, true, ["deriveBits"]);
  const jwk = await subtle.exportKey("jwk", priv);
  return { priv, pub: new Uint8Array(Buffer.from(jwk.x, "base64url")) };
}
const ed25519Sign = async (priv, msg) => new Uint8Array(await subtle.sign({ name: "Ed25519" }, priv, msg));

async function aesGcm(key, nonce, aad, plaintext) {
  const k = await subtle.importKey("raw", key, { name: "AES-GCM" }, false, ["encrypt"]);
  return new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad, tagLength: 128 }, k, plaintext));
}

// ---- fixed inputs ------------------------------------------------------------
const groupId = "01JBX8G7R5ZK4Q2M9N3PDT6WAC";
const accountId = "K7M2Q9XA";
const memberId = "7M3Q9ZR4K2X8N5PDT6WACB1HJE"; // the signing account's seat (wrapper / author)
const targetMemberId = "5C8W2N6R9T3K7XZ4P1QMDHAJBG"; // the wrap recipient
const eventId = "01JBX8H2Q4S6T8V0W2Y4Z6A8C0";
const epoch = 3;

const signSeed = seq(0x01, 32);
const memberRoomSeed = seq(0x21, 32); // memberId's own room X25519 key (its pubKey is what memberKeySig binds)
const recipientSeed = seq(0x41, 32);
const ephemeralSeed = seq(0x61, 32);
const roomKey = seq(0x81, 32);
const wrapNonce = seq(0xa1, 12);
const msgNonce = seq(0xb1, 12);
const metaNonce = seq(0xc1, 12);
const msgPlaintext = "哈囉，群組！Hello group 👋";
const metaPlaintext = '{"name":"週末爬山","category":"興趣"}';

const signer = await ed25519(signSeed);
const memberRoom = await x25519(memberRoomSeed);
const recipient = await x25519(recipientSeed);
const ephemeral = await x25519(ephemeralSeed);

// ---- memberKeySig --------------------------------------------------------------
const mkMessage = concat(utf8("PDGRPMK1"), utf8(groupId), utf8(memberId), utf8(accountId), memberRoom.pub);
const mkSig = await ed25519Sign(signer.priv, mkMessage);

// ---- wrap ----------------------------------------------------------------------
const recipientPubKey = await subtle.importKey("raw", recipient.pub, { name: "X25519" }, true, []);
const sharedSecret = new Uint8Array(await subtle.deriveBits({ name: "X25519", public: recipientPubKey }, ephemeral.priv, 256));
const hkdfIkm = await subtle.importKey("raw", sharedSecret, "HKDF", false, ["deriveBits"]);
const wrapSalt = concat(ephemeral.pub, recipient.pub);
const wrapInfo = "peerdrop-group-wrap-v1";
const wrapKey = new Uint8Array(await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: wrapSalt, info: utf8(wrapInfo) }, hkdfIkm, 256));
const wrapAad = concat(utf8(groupId), u32be(epoch), utf8(targetMemberId));
const wrapSealed = await aesGcm(wrapKey, wrapNonce, wrapAad, roomKey); // ciphertext(32) ‖ tag(16)
const wrapped = concat(ephemeral.pub, wrapNonce, wrapSealed);
if (wrapped.length !== 92) throw new Error("wrapped must be 92 bytes");

// ---- wrapSig -------------------------------------------------------------------
const wsMessage = concat(utf8("PDGRPWK1"), utf8(groupId), u32be(epoch), utf8(targetMemberId), utf8(memberId), wrapped);
const wsSig = await ed25519Sign(signer.priv, wsMessage);

// ---- message -------------------------------------------------------------------
const msgAad = concat(utf8(groupId), utf8(memberId), utf8(eventId), u32be(epoch));
const msgPayload = concat(msgNonce, await aesGcm(roomKey, msgNonce, msgAad, utf8(msgPlaintext)));

// ---- metaCipher ----------------------------------------------------------------
const metaAad = concat(utf8(groupId), u32be(epoch), utf8("meta"));
const metaCipher = concat(metaNonce, await aesGcm(roomKey, metaNonce, metaAad, utf8(metaPlaintext)));

const out = {
  description: [
    "PeerDrop group room (project G) shared crypto vectors. Generated by cloudflare-worker/scripts/gen-group-vectors.mjs (Node WebCrypto, every input fixed; Ed25519 is deterministic, so regeneration is byte-identical). Checked server-side by src/__tests__/group-vectors.spec.ts; G1b's GroupCrypto tests must consume this same file.",
    "Encoding: *Hex fields are lowercase hex; *B64 fields are standard base64 WITH padding (the wire format of every /v3/groups field); ids and plaintexts are UTF-8 strings; UInt32BE = 4-byte big-endian unsigned; ‖ = byte concatenation. groupId / memberId / eventId are 26-char Crockford base32 (ULID alphabet), accountId is 8 chars, so every concatenated field is fixed-length and no separators are used.",
    "Keys: Ed25519 and X25519 private keys are given as their raw 32-byte seed (RFC 8032 / RFC 7748 private key); the public keys are the raw 32-byte encodings. signing.publicKeyHex is what the server stores as accounts.signing_key.",
    "memberKeySig: message = utf8(\"PDGRPMK1\") ‖ utf8(groupId) ‖ utf8(memberId) ‖ utf8(accountId) ‖ pubKey(32) (8+26+26+8+32 = 100 bytes); signature = Ed25519(signing key, message). pubKey is the member's own room X25519 public key, sent as `pubKey` with `pubKeySig` on create / account join.",
    "wrap: sharedSecret = X25519(ephemeralPriv, recipientPub) (32 B); wrapKey = HKDF-SHA256(ikm = sharedSecret, salt = ephemeralPub ‖ recipientPub, info = utf8(\"peerdrop-group-wrap-v1\"), L = 32); aad = utf8(groupId) ‖ UInt32BE(epoch) ‖ utf8(memberId of the RECIPIENT); wrapped = ephemeralPub(32) ‖ nonce(12) ‖ AES-256-GCM(wrapKey, nonce, aad, roomKey) ciphertext(32) ‖ tag(16) = 92 bytes. The recipient recomputes sharedSecret = X25519(recipientPriv, ephemeralPub). A fresh ephemeral key and nonce per wrap.",
    "wrapSig: message = utf8(\"PDGRPWK1\") ‖ utf8(groupId) ‖ UInt32BE(epoch) ‖ utf8(targetMemberId) ‖ utf8(wrapperMemberId) ‖ wrapped(92) (8+26+4+26+26+92 = 182 bytes); signature = Ed25519(the WRAPPER's account signing key, message). wrapperMemberId is the caller's X-Group-Member-Id (what the room records as wrappedBy). The server verifies it on create (ownerWrap: epoch 1, target = wrapper = owner), PUT /keys and POST /rotate.",
    "message: aad = utf8(groupId) ‖ utf8(authorMemberId) ‖ utf8(eventId) ‖ UInt32BE(epoch); payloadCipher = base64(nonce(12) ‖ AES-256-GCM(roomKey of that epoch, nonce, aad, utf8(plaintext)) ciphertext ‖ tag(16)).",
    "metaCipher: aad = utf8(groupId) ‖ UInt32BE(epoch) ‖ utf8(\"meta\"); metaCipher = base64(nonce(12) ‖ ciphertext ‖ tag(16)) under the roomKey of `epoch` (the epoch current when it was written; a rotation re-encrypts it under the new epoch). The plaintext's JSON shape is a client matter; the one here is only sample text.",
    "The server never decrypts anything: it only checks the two Ed25519 signatures (Ruling 6) and byte lengths. Clients MUST still verify both signatures themselves.",
  ],
  inputs: {
    groupId, accountId, memberId, targetMemberId, eventId, epoch,
  },
  signing: {
    seedHex: hex(signSeed),
    publicKeyHex: hex(signer.pub),
    publicKeyB64: b64(signer.pub),
  },
  memberKeySig: {
    groupId, memberId, accountId,
    roomPrivateKeyHex: hex(memberRoomSeed),
    pubKeyHex: hex(memberRoom.pub),
    pubKeyB64: b64(memberRoom.pub),
    messageHex: hex(mkMessage),
    signatureHex: hex(mkSig),
    signatureB64: b64(mkSig),
  },
  wrap: {
    groupId, epoch, memberId: targetMemberId,
    recipientPrivateKeyHex: hex(recipientSeed),
    recipientPublicKeyHex: hex(recipient.pub),
    ephemeralPrivateKeyHex: hex(ephemeralSeed),
    ephemeralPublicKeyHex: hex(ephemeral.pub),
    roomKeyHex: hex(roomKey),
    nonceHex: hex(wrapNonce),
    sharedSecretHex: hex(sharedSecret),
    hkdfSaltHex: hex(wrapSalt),
    hkdfInfo: wrapInfo,
    wrapKeyHex: hex(wrapKey),
    aadHex: hex(wrapAad),
    wrappedHex: hex(wrapped),
    wrappedB64: b64(wrapped),
  },
  wrapSig: {
    groupId, epoch, targetMemberId, wrapperMemberId: memberId,
    wrappedB64: b64(wrapped),
    messageHex: hex(wsMessage),
    signatureHex: hex(wsSig),
    signatureB64: b64(wsSig),
  },
  message: {
    groupId, memberId, eventId, epoch,
    roomKeyHex: hex(roomKey),
    nonceHex: hex(msgNonce),
    plaintext: msgPlaintext,
    aadHex: hex(msgAad),
    payloadCipherB64: b64(msgPayload),
  },
  metaCipher: {
    groupId, epoch,
    roomKeyHex: hex(roomKey),
    nonceHex: hex(metaNonce),
    plaintext: metaPlaintext,
    aadHex: hex(metaAad),
    metaCipherB64: b64(metaCipher),
  },
};
process.stdout.write(JSON.stringify(out, null, 1) + "\n");
