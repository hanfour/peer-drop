// Apple App Attest attestation + assertion verification, ported to
// Cloudflare Workers. Replaces the Node-only `node-app-attest`
// (`crypto.X509Certificate` isn't available on workerd) with
// `pkijs` + `asn1js` + `cbor2`, all pure-JS and Web-Crypto-backed.
//
// Spec: https://developer.apple.com/documentation/devicecheck/validating_apps_that_connect_to_your_server
//
// Threat model: a malicious client can craft any CBOR payload they
// want. The defense relies on:
//   1. The leaf cert's chain ending at Apple's hardcoded App
//      Attestation Root CA (pinned below).
//   2. The leaf cert's `1.2.840.113635.100.8.2` extension binding the
//      attestation challenge to the credential — this is what makes
//      replays impossible.
//   3. The AAGUID magic identifying App Attest as the issuer (not
//      WebAuthn or another DCAttestable client).
//
// Skipping any of those = the worker accepts forged attestations.

import { decode as cborDecode } from "cbor2";
import * as asn1js from "asn1js";
import { Certificate, CertificateChainValidationEngine, CryptoEngine, setEngine } from "pkijs";

// =====================================================================
// Apple App Attestation Root CA — pin via the well-known cert below.
// Source: https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
// =====================================================================

const APPLE_APP_ATTEST_ROOT_PEM = `MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD`;

// AAGUID magic that App Attest stamps into the attested credential.
// Two 16-byte values: production and development. The spec says
// `appattestdevelop` UTF-8 padded to 16 bytes for dev, and `appattest`
// + 7 null bytes for prod.
const AAGUID_PROD = utf8Bytes("appattest\0\0\0\0\0\0\0");
const AAGUID_DEV = utf8Bytes("appattestdevelop");

// OID for the App Attest nonce extension on the leaf credCert.
const APP_ATTEST_NONCE_OID = "1.2.840.113635.100.8.2";

// pkijs needs a CryptoEngine pointing at Web Crypto. The Workers runtime
// has both `crypto` and `crypto.subtle` globally. The type cast routes
// around a missing `timingSafeEqual` in the pkijs type defs — pkijs
// itself never calls it in our verification paths.
let cryptoEngineInitialized = false;
function ensurePKIJSEngine(): void {
  if (cryptoEngineInitialized) return;
  const engine = new CryptoEngine({ crypto, subtle: crypto.subtle, name: "workers" });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  setEngine("workers", engine as any);
  cryptoEngineInitialized = true;
}

// =====================================================================
// Types
// =====================================================================

export interface AttestationInput {
  attestation: Uint8Array;     // CBOR attestation object
  challenge: Uint8Array;       // clientDataHash (32 bytes; usually SHA-256 of a server nonce)
  keyId: Uint8Array;           // base64-decoded keyId from DCAppAttestService
  bundleIdentifier: string;    // e.g. "com.hanfour.peerdrop"
  teamIdentifier: string;      // e.g. "UK48R5KWLV"
  allowDevelopmentEnvironment?: boolean;
}

export interface AttestationResult {
  publicKeyDer: Uint8Array;    // Cache this for later assertions
  receipt: Uint8Array;         // Apple receipt — used by the renew flow we don't ship yet
  counter: number;             // Always 0 for attestation
}

export interface AssertionInput {
  assertion: Uint8Array;         // CBOR assertion object
  clientData: Uint8Array;        // Raw client data; we hash it ourselves
  publicKeyDer: Uint8Array;      // From a prior verifyAttestation()
  previousCounter: number;
  bundleIdentifier: string;
  teamIdentifier: string;
}

export interface AssertionResult {
  newCounter: number;
}

// =====================================================================
// Attestation verification
// =====================================================================

export async function verifyAttestation(input: AttestationInput): Promise<AttestationResult> {
  ensurePKIJSEngine();

  // ─── Step 1: CBOR decode the attestation envelope ────────────────────
  let decoded: AttestationCBOR;
  try {
    decoded = cborDecode(input.attestation) as AttestationCBOR;
  } catch (err) {
    throw new Error(`CBOR decode failed: ${(err as Error).message}`);
  }

  if (!decoded || typeof decoded !== "object") {
    throw new Error("Attestation is not a CBOR map");
  }
  if (decoded.fmt !== "apple-appattest") {
    throw new Error(`Unexpected fmt: ${decoded.fmt}`);
  }
  if (!decoded.attStmt || !Array.isArray(decoded.attStmt.x5c) || decoded.attStmt.x5c.length !== 2) {
    throw new Error("attStmt.x5c must have exactly [credCert, intermediate]");
  }
  if (!(decoded.attStmt.receipt instanceof Uint8Array)) {
    throw new Error("attStmt.receipt missing or non-binary");
  }
  if (!(decoded.authData instanceof Uint8Array)) {
    throw new Error("authData missing or non-binary");
  }

  const credCertDer = ensureUint8(decoded.attStmt.x5c[0], "credCert");
  const intermediateDer = ensureUint8(decoded.attStmt.x5c[1], "intermediate");
  const authData = decoded.authData;
  const receipt = decoded.attStmt.receipt;

  // ─── Step 2: Verify cert chain to Apple's App Attestation root ───────
  const rootDer = pemToDer(APPLE_APP_ATTEST_ROOT_PEM);
  const credCert = certFromDer(credCertDer);
  const intermediate = certFromDer(intermediateDer);
  const root = certFromDer(rootDer);

  const chain = new CertificateChainValidationEngine({
    trustedCerts: [root],
    certs: [credCert, intermediate],
  });
  const chainResult = await chain.verify();
  if (!chainResult.result) {
    throw new Error(`Cert chain rejected: ${chainResult.resultMessage}`);
  }

  // ─── Step 3: Verify the nonce extension on credCert ──────────────────
  // The leaf carries `1.2.840.113635.100.8.2`, an OCTET STRING wrapping a
  // SEQUENCE { context[1] OCTET STRING }. The inner octets must equal
  // SHA-256(authData || clientDataHash).
  const nonce = await sha256(concat(authData, input.challenge));
  const certNonce = extractAppAttestNonce(credCert);
  if (!constantTimeEq(certNonce, nonce)) {
    throw new Error("Attestation nonce mismatch (credCert nonce extension vs SHA-256(authData||challenge))");
  }

  // ─── Step 4: Parse authData and validate fields ──────────────────────
  const parsed = parseAuthData(authData);

  const expectedRpIdHash = await sha256(utf8Bytes(`${input.teamIdentifier}.${input.bundleIdentifier}`));
  if (!constantTimeEq(parsed.rpIdHash, expectedRpIdHash)) {
    throw new Error("rpIdHash mismatch");
  }
  if (parsed.counter !== 0) {
    throw new Error(`Attestation counter must be 0, got ${parsed.counter}`);
  }

  const aaguidMatchesProd = constantTimeEq(parsed.aaguid, AAGUID_PROD);
  const aaguidMatchesDev = constantTimeEq(parsed.aaguid, AAGUID_DEV);
  if (!aaguidMatchesProd && !(aaguidMatchesDev && input.allowDevelopmentEnvironment)) {
    throw new Error(`AAGUID rejected (dev allowed = ${!!input.allowDevelopmentEnvironment})`);
  }

  // credentialId must equal keyId from DCAppAttestService — the client
  // identifies the same key both ways and Apple's framework ties them.
  if (!constantTimeEq(parsed.credentialId, input.keyId)) {
    throw new Error("credentialId in authData does not match supplied keyId");
  }

  // ─── Step 5: cred-cert pubkey must equal authData's COSE pubkey ──────
  const certPubKeyDer = await spkiFromCert(credCert);
  const cosePubKeyDer = coseEc2ToSpkiDer(parsed.coseEc2);
  if (!constantTimeEq(certPubKeyDer, cosePubKeyDer)) {
    throw new Error("Public key in credCert does not match credentialPublicKey in authData");
  }

  return {
    publicKeyDer: cosePubKeyDer,
    receipt,
    counter: 0,
  };
}

// =====================================================================
// Assertion verification
// =====================================================================

export async function verifyAssertion(input: AssertionInput): Promise<AssertionResult> {
  ensurePKIJSEngine();

  // ─── Step 1: CBOR decode assertion ───────────────────────────────────
  let decoded: AssertionCBOR;
  try {
    decoded = cborDecode(input.assertion) as AssertionCBOR;
  } catch (err) {
    throw new Error(`CBOR decode failed: ${(err as Error).message}`);
  }
  if (!decoded || typeof decoded !== "object") {
    throw new Error("Assertion is not a CBOR map");
  }
  const sig = ensureUint8(decoded.signature, "signature");
  const authenticatorData = ensureUint8(decoded.authenticatorData, "authenticatorData");

  // ─── Step 2: Validate rpIdHash + counter ─────────────────────────────
  // authenticatorData for assertions is just rpIdHash (32) + flags (1) + counter (4 BE).
  if (authenticatorData.length < 37) {
    throw new Error(`authenticatorData too short: ${authenticatorData.length}`);
  }
  const rpIdHash = authenticatorData.subarray(0, 32);
  const counter = readUint32BE(authenticatorData, 33);

  const expectedRpIdHash = await sha256(utf8Bytes(`${input.teamIdentifier}.${input.bundleIdentifier}`));
  if (!constantTimeEq(rpIdHash, expectedRpIdHash)) {
    throw new Error("rpIdHash mismatch");
  }
  if (counter <= input.previousCounter) {
    throw new Error(`Counter not strictly increasing: ${counter} <= ${input.previousCounter}`);
  }

  // ─── Step 3: Verify signature over SHA-256(authData||clientDataHash) ─
  const clientDataHash = await sha256(input.clientData);
  const signedNonce = await sha256(concat(authenticatorData, clientDataHash));

  // The signature is ECDSA-DER. Web Crypto's `verify` expects raw r||s
  // when alg is ECDSA. Convert.
  const sigRaw = ecdsaDerToRaw(sig, 32);
  const key = await crypto.subtle.importKey(
    "spki",
    input.publicKeyDer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    sigRaw,
    signedNonce,
  );
  if (!valid) {
    throw new Error("Assertion signature does not verify against cached publicKey");
  }

  return { newCounter: counter };
}

// =====================================================================
// authData parser
// =====================================================================

interface AuthDataParsed {
  rpIdHash: Uint8Array;
  flags: number;
  counter: number;
  aaguid: Uint8Array;
  credentialId: Uint8Array;
  coseEc2: CoseEC2Key;
}

interface CoseEC2Key {
  x: Uint8Array; // 32 bytes
  y: Uint8Array; // 32 bytes
}

function parseAuthData(authData: Uint8Array): AuthDataParsed {
  // 32 + 1 + 4 + 16 + 2 = 55 byte minimum, then credentialId + COSE key.
  if (authData.length < 55) {
    throw new Error(`authData too short for attestation: ${authData.length}`);
  }
  const rpIdHash = authData.subarray(0, 32);
  const flags = authData[32];
  const counter = readUint32BE(authData, 33);
  const aaguid = authData.subarray(37, 53);
  const credentialIdLen = (authData[53] << 8) | authData[54];
  if (authData.length < 55 + credentialIdLen) {
    throw new Error(`authData truncated for credentialId len ${credentialIdLen}`);
  }
  const credentialId = authData.subarray(55, 55 + credentialIdLen);
  const coseBytes = authData.subarray(55 + credentialIdLen);
  const coseDecoded = cborDecode(coseBytes) as CoseRawKey;
  const coseEc2 = parseCoseEC2(coseDecoded);

  return { rpIdHash, flags, counter, aaguid, credentialId, coseEc2 };
}

type CoseRawKey = Map<number, number | Uint8Array>;

function parseCoseEC2(cose: CoseRawKey): CoseEC2Key {
  // Required: kty=2 (EC2), alg=-7 (ES256), crv=1 (P-256), x, y.
  const kty = cose.get(1);
  const alg = cose.get(3);
  const crv = cose.get(-1);
  const x = cose.get(-2);
  const y = cose.get(-3);
  if (kty !== 2) throw new Error(`COSE key not EC2 (kty=${kty})`);
  if (alg !== -7) throw new Error(`COSE key alg not ES256 (alg=${alg})`);
  if (crv !== 1) throw new Error(`COSE key crv not P-256 (crv=${crv})`);
  if (!(x instanceof Uint8Array) || x.length !== 32) throw new Error("COSE key x not 32 bytes");
  if (!(y instanceof Uint8Array) || y.length !== 32) throw new Error("COSE key y not 32 bytes");
  return { x, y };
}

function coseEc2ToSpkiDer(key: CoseEC2Key): Uint8Array {
  // SPKI for P-256: 0x30 0x59 0x30 0x13 0x06 0x07 2A8648CE3D0201 0x06 0x08 2A8648CE3D030107 0x03 0x42 0x00 0x04 || x || y
  const prefix = new Uint8Array([
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04,
  ]);
  const out = new Uint8Array(prefix.length + 64);
  out.set(prefix, 0);
  out.set(key.x, prefix.length);
  out.set(key.y, prefix.length + 32);
  return out;
}

// =====================================================================
// Cert helpers
// =====================================================================

function pemToDer(pem: string): Uint8Array {
  const clean = pem.replace(/-----BEGIN [^-]+-----|-----END [^-]+-----|\s/g, "");
  const bin = atob(clean);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function certFromDer(der: Uint8Array): Certificate {
  const asn1 = asn1js.fromBER(der.buffer.slice(der.byteOffset, der.byteOffset + der.byteLength) as ArrayBuffer);
  if (asn1.offset === -1) throw new Error("Cert parse failed");
  return new Certificate({ schema: asn1.result });
}

async function spkiFromCert(cert: Certificate): Promise<Uint8Array> {
  const spkiBer = cert.subjectPublicKeyInfo.toSchema().toBER(false);
  return new Uint8Array(spkiBer);
}

function extractAppAttestNonce(cert: Certificate): Uint8Array {
  const ext = cert.extensions?.find(e => e.extnID === APP_ATTEST_NONCE_OID);
  if (!ext) throw new Error("credCert missing App Attest nonce extension");
  const innerBer = ext.extnValue.valueBlock.valueHex;
  const asn1 = asn1js.fromBER(innerBer);
  if (asn1.offset === -1) throw new Error("Nonce extension SEQUENCE parse failed");
  const seq = asn1.result as asn1js.Sequence;
  const inner = seq.valueBlock.value[0];
  if (!inner) throw new Error("Nonce extension SEQUENCE empty");
  // The inner is [1] EXPLICIT OCTET STRING — the constructed context tag.
  const tagged = inner as asn1js.Constructed;
  const octets = tagged.valueBlock.value[0] as asn1js.OctetString;
  return new Uint8Array(octets.valueBlock.valueHex);
}

// =====================================================================
// CBOR shape
// =====================================================================

interface AttestationCBOR {
  fmt: string;
  attStmt: {
    x5c: unknown[];
    receipt: Uint8Array;
  };
  authData: Uint8Array;
}

interface AssertionCBOR {
  signature: Uint8Array;
  authenticatorData: Uint8Array;
}

function ensureUint8(v: unknown, label: string): Uint8Array {
  if (v instanceof Uint8Array) return v;
  // Some CBOR decoders return ArrayBuffer for byte strings.
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  throw new Error(`${label} must be a byte string`);
}

// =====================================================================
// Small crypto + byte helpers
// =====================================================================

function utf8Bytes(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const dataBuf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", dataBuf));
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/// Constant-time byte-array equality. Returns false fast if lengths differ
/// (length is public anyway), then compares every byte to avoid leaking
/// position-of-first-difference timing.
function constantTimeEq(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

function readUint32BE(b: Uint8Array, offset: number): number {
  return (b[offset] << 24 | b[offset + 1] << 16 | b[offset + 2] << 8 | b[offset + 3]) >>> 0;
}

/// Convert an ECDSA DER signature (SEQUENCE of two INTEGER r, s) to the
/// raw r||s concatenation Web Crypto's `verify` expects. r and s are
/// padded to `n` bytes (32 for P-256).
function ecdsaDerToRaw(der: Uint8Array, n: number): Uint8Array {
  if (der[0] !== 0x30) throw new Error("ECDSA signature not a SEQUENCE");
  let i = 2;
  // INTEGER r
  if (der[i] !== 0x02) throw new Error("ECDSA r not INTEGER");
  let rLen = der[i + 1];
  let rStart = i + 2;
  // Strip leading 0x00 used for sign bit.
  while (rLen > n) { rStart++; rLen--; }
  // Pad if shorter.
  const r = new Uint8Array(n);
  r.set(der.subarray(rStart, rStart + rLen), n - rLen);
  i = rStart + rLen;
  // INTEGER s
  if (der[i] !== 0x02) throw new Error("ECDSA s not INTEGER");
  let sLen = der[i + 1];
  let sStart = i + 2;
  while (sLen > n) { sStart++; sLen--; }
  const s = new Uint8Array(n);
  s.set(der.subarray(sStart, sStart + sLen), n - sLen);
  return concat(r, s);
}
