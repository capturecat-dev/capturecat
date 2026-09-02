/**
 * Apple App Attest verification for Cloudflare Workers — WebCrypto only,
 * no dependencies. Implements the checks from Apple's "Validating apps that
 * connect to your server" doc:
 *
 *  Attestation (key registration):
 *   1. CBOR-decode the attestation object; format must be "apple-appattest".
 *   2. Verify the x5c chain: credCert ← intermediate ← pinned Apple root.
 *   3. nonce = SHA256(authData ‖ clientDataHash) must equal the value inside
 *      credCert extension OID 1.2.840.113635.100.8.2.
 *   4. Key identifier = SHA256(credCert public key) must match the client's
 *      key id AND the credentialId in authData.
 *   5. authData RP ID hash must equal SHA256(App ID); counter must be 0;
 *      aaguid must be "appattest" (prod) or "appattest\0\0\0\0\0\0\0" (dev).
 *
 *  Assertion (per-request):
 *   1. CBOR-decode {signature, authenticatorData}.
 *   2. Verify ES256 signature over SHA256(authenticatorData ‖ clientDataHash)
 *      with the registered public key.
 *   3. RP ID hash matches; counter strictly increases.
 */

// Pinned Apple App Attestation Root CA
// (https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem)
export const APPLE_APP_ATTEST_ROOT_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
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
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

// ── small helpers ───────────────────────────────────────────────────────────

export function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data as BufferSource));
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

function pemToDer(pem: string): Uint8Array {
  return b64ToBytes(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""));
}

// ── minimal CBOR decoder (maps, arrays, byte/text strings, uints) ───────────

class CborReader {
  private view: DataView;
  private pos = 0;
  constructor(private bytes: Uint8Array) {
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  decode(): unknown {
    const initial = this.bytes[this.pos++];
    const major = initial >> 5;
    const info = initial & 0x1f;
    const length = this.readLength(info);

    switch (major) {
      case 0: // unsigned int
        return length;
      case 1: // negative int
        return -1 - Number(length);
      case 2: { // byte string
        const out = this.bytes.slice(this.pos, this.pos + Number(length));
        this.pos += Number(length);
        return out;
      }
      case 3: { // text string
        const out = new TextDecoder().decode(
          this.bytes.slice(this.pos, this.pos + Number(length)),
        );
        this.pos += Number(length);
        return out;
      }
      case 4: { // array
        const arr: unknown[] = [];
        for (let i = 0; i < Number(length); i++) arr.push(this.decode());
        return arr;
      }
      case 5: { // map
        const map: Record<string, unknown> = {};
        for (let i = 0; i < Number(length); i++) {
          const key = this.decode();
          map[String(key)] = this.decode();
        }
        return map;
      }
      case 7: // simple values / floats — attestation objects don't need them
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        throw new Error("cbor: unsupported simple/float");
      default:
        throw new Error(`cbor: unsupported major type ${major}`);
    }
  }

  private readLength(info: number): number {
    if (info < 24) return info;
    if (info === 24) return this.bytes[this.pos++];
    if (info === 25) {
      const v = this.view.getUint16(this.pos);
      this.pos += 2;
      return v;
    }
    if (info === 26) {
      const v = this.view.getUint32(this.pos);
      this.pos += 4;
      return v;
    }
    if (info === 27) {
      const v = this.view.getBigUint64(this.pos);
      this.pos += 8;
      if (v > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("cbor: length too large");
      return Number(v);
    }
    throw new Error("cbor: indefinite lengths unsupported");
  }
}

export function cborDecode(bytes: Uint8Array): unknown {
  return new CborReader(bytes).decode();
}

// ── minimal DER/ASN.1 reader (enough for X.509) ─────────────────────────────

interface DerNode {
  tag: number;
  constructed: boolean;
  /** content bytes (without header) */
  content: Uint8Array;
  /** full element bytes (with header) — needed for signature inputs */
  raw: Uint8Array;
  children: DerNode[];
}

function parseDer(bytes: Uint8Array, offset = 0): { node: DerNode; end: number } {
  const start = offset;
  const tag = bytes[offset++];
  let len = bytes[offset++];
  if (len & 0x80) {
    const numBytes = len & 0x7f;
    len = 0;
    for (let i = 0; i < numBytes; i++) len = len * 256 + bytes[offset++];
  }
  const content = bytes.slice(offset, offset + len);
  const end = offset + len;
  const raw = bytes.slice(start, end);
  const constructed = (tag & 0x20) !== 0;
  const children: DerNode[] = [];
  if (constructed) {
    let p = offset;
    while (p < end) {
      const child = parseDer(bytes, p);
      children.push(child.node);
      p = child.end;
    }
  }
  return { node: { tag, constructed, content, raw, children }, end };
}

interface ParsedCert {
  tbs: Uint8Array;           // full DER of tbsCertificate
  signature: Uint8Array;     // DER ECDSA signature over tbs
  spki: Uint8Array;          // subjectPublicKeyInfo DER
  sigAlgOid: string;
  /** extension OID → raw extnValue (content of the OCTET STRING) */
  extensions: Map<string, Uint8Array>;
}

function oidToString(content: Uint8Array): string {
  const first = content[0];
  const parts = [Math.floor(first / 40), first % 40];
  let value = 0;
  for (let i = 1; i < content.length; i++) {
    value = value * 128 + (content[i] & 0x7f);
    if ((content[i] & 0x80) === 0) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

export function parseCertificate(der: Uint8Array): ParsedCert {
  const cert = parseDer(der).node;
  if (cert.children.length < 3) throw new Error("x509: malformed certificate");
  const [tbs, sigAlg, sigValue] = cert.children;

  const sigAlgOid = oidToString(sigAlg.children[0].content);

  // signatureValue is a BIT STRING; first content byte = unused-bits count
  const signature = sigValue.content.slice(1);

  // tbsCertificate children: [0] version, serial, sigAlg, issuer, validity,
  // subject, subjectPublicKeyInfo, ... extensions [3]
  let idx = 0;
  if (tbs.children[0].tag === 0xa0) idx = 1; // explicit version present
  const spkiNode = tbs.children[idx + 5];
  const extensions = new Map<string, Uint8Array>();
  for (const child of tbs.children) {
    if (child.tag === 0xa3) {
      // Extensions ::= SEQUENCE OF Extension
      for (const ext of child.children[0].children) {
        const oid = oidToString(ext.children[0].content);
        // extnValue is the last child (skip optional critical BOOLEAN)
        const extnValue = ext.children[ext.children.length - 1];
        extensions.set(oid, extnValue.content);
      }
    }
  }

  return { tbs: tbs.raw, signature, spki: spkiNode.raw, sigAlgOid, extensions };
}

/** DER ECDSA-Sig-Value {r, s} → raw r‖s for WebCrypto. */
function derSigToRaw(der: Uint8Array, size: number): Uint8Array {
  const seq = parseDer(der).node;
  const toFixed = (n: Uint8Array): Uint8Array => {
    let v = n;
    while (v.length > size && v[0] === 0) v = v.slice(1);
    if (v.length > size) throw new Error("ecdsa: integer too large");
    const out = new Uint8Array(size);
    out.set(v, size - v.length);
    return out;
  };
  return concat(toFixed(seq.children[0].content), toFixed(seq.children[1].content));
}

async function importSpki(spki: Uint8Array, curve: "P-256" | "P-384"): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "spki",
    spki as BufferSource,
    { name: "ECDSA", namedCurve: curve },
    true,
    ["verify"],
  );
}

/** Verify `child` is signed by `issuerSpki` (ECDSA SHA-256/384 by OID). */
async function verifyCertSignature(child: ParsedCert, issuerSpki: Uint8Array): Promise<boolean> {
  // 1.2.840.10045.4.3.2 = ecdsa-with-SHA256, 1.2.840.10045.4.3.3 = SHA384
  const isSha384 = child.sigAlgOid === "1.2.840.10045.4.3.3";
  const hash = isSha384 ? "SHA-384" : "SHA-256";
  const size = isSha384 ? 48 : 32;
  // Apple's chain uses P-256 leaf/intermediate and a P-384 root; the curve of
  // the VERIFYING key comes from the issuer's SPKI — try P-256 then P-384.
  for (const curve of ["P-256", "P-384"] as const) {
    try {
      const key = await importSpki(issuerSpki, curve);
      const ok = await crypto.subtle.verify(
        { name: "ECDSA", hash },
        key,
        derSigToRaw(child.signature, size) as BufferSource,
        child.tbs as BufferSource,
      );
      if (ok) return true;
    } catch {
      // wrong curve for this SPKI — try the next
    }
  }
  return false;
}

// ── attestation ─────────────────────────────────────────────────────────────

const APPLE_NONCE_OID = "1.2.840.113635.100.8.2";

export interface AttestationResult {
  keyId: string;          // base64 of SHA256(public key) — Apple's key id
  publicKeySpki: string;  // base64 DER SPKI, stored for assertion checks
  counter: number;
}

export async function verifyAttestation(params: {
  attestationB64: string;
  keyIdB64: string;
  challenge: Uint8Array;
  appId: string;          // "TEAMID.bundle.id"
  allowDevelopment: boolean;
}): Promise<AttestationResult> {
  const obj = cborDecode(b64ToBytes(params.attestationB64)) as {
    fmt: string;
    attStmt: { x5c: Uint8Array[]; receipt: Uint8Array };
    authData: Uint8Array;
  };
  if (obj.fmt !== "apple-appattest") throw new Error("attest: wrong fmt");
  const x5c = obj.attStmt.x5c;
  if (!Array.isArray(x5c) || x5c.length < 2) throw new Error("attest: missing x5c");

  const credCert = parseCertificate(x5c[0]);
  const intermediate = parseCertificate(x5c[1]);
  const root = parseCertificate(pemToDer(APPLE_APP_ATTEST_ROOT_PEM));

  // 2. chain: credCert ← intermediate ← pinned root
  if (!(await verifyCertSignature(credCert, intermediate.spki))) {
    throw new Error("attest: credCert not signed by intermediate");
  }
  if (!(await verifyCertSignature(intermediate, root.spki))) {
    throw new Error("attest: intermediate not signed by Apple root");
  }

  // 3. nonce
  const clientDataHash = await sha256(params.challenge);
  const nonce = await sha256(concat(obj.authData, clientDataHash));
  const ext = credCert.extensions.get(APPLE_NONCE_OID);
  if (!ext) throw new Error("attest: nonce extension missing");
  // extnValue: SEQUENCE { [1] { OCTET STRING nonce } }
  const seq = parseDer(ext).node;
  const inner = seq.children[0]?.children[0];
  if (!inner || !bytesEqual(inner.content, nonce)) {
    throw new Error("attest: nonce mismatch");
  }

  // 4. key id = SHA256(uncompressed public key point)
  // SPKI ends with a BIT STRING holding 0x00 ‖ uncompressed point.
  const spkiNode = parseDer(credCert.spki).node;
  const pubPoint = spkiNode.children[1].content.slice(1);
  const computedKeyId = await sha256(pubPoint);
  const claimedKeyId = b64ToBytes(params.keyIdB64);
  if (!bytesEqual(computedKeyId, claimedKeyId)) {
    throw new Error("attest: keyId mismatch");
  }

  // 5. authData checks
  const authData = obj.authData;
  const rpIdHash = authData.slice(0, 32);
  const expectedRpId = await sha256(new TextEncoder().encode(params.appId));
  if (!bytesEqual(rpIdHash, expectedRpId)) throw new Error("attest: appId mismatch");

  const counter = new DataView(
    authData.buffer, authData.byteOffset + 33, 4,
  ).getUint32(0);
  if (counter !== 0) throw new Error("attest: nonzero initial counter");

  const aaguid = new TextDecoder().decode(authData.slice(37, 53)).replace(/\0+$/, "");
  if (aaguid !== "appattest" && !(params.allowDevelopment && aaguid === "appattestdevelop")) {
    throw new Error(`attest: unexpected aaguid "${aaguid}"`);
  }

  const credIdLen = new DataView(authData.buffer, authData.byteOffset + 53, 2).getUint16(0);
  const credId = authData.slice(55, 55 + credIdLen);
  if (!bytesEqual(credId, claimedKeyId)) throw new Error("attest: credentialId mismatch");

  return {
    keyId: params.keyIdB64,
    publicKeySpki: btoa(String.fromCharCode(...credCert.spki)),
    counter: 0,
  };
}

// ── assertion ───────────────────────────────────────────────────────────────

export async function verifyAssertion(params: {
  assertionB64: string;
  clientData: Uint8Array;   // the exact bytes the client hashed (request body)
  publicKeySpkiB64: string;
  appId: string;
  lastCounter: number;
}): Promise<{ counter: number }> {
  const obj = cborDecode(b64ToBytes(params.assertionB64)) as {
    signature: Uint8Array;
    authenticatorData: Uint8Array;
  };
  const clientDataHash = await sha256(params.clientData);
  const nonce = await sha256(concat(obj.authenticatorData, clientDataHash));

  const key = await importSpki(b64ToBytes(params.publicKeySpkiB64), "P-256");
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    derSigToRaw(obj.signature, 32) as BufferSource,
    nonce as BufferSource,
  );
  if (!ok) throw new Error("assert: bad signature");

  const rpIdHash = obj.authenticatorData.slice(0, 32);
  const expectedRpId = await sha256(new TextEncoder().encode(params.appId));
  if (!bytesEqual(rpIdHash, expectedRpId)) throw new Error("assert: appId mismatch");

  const counter = new DataView(
    obj.authenticatorData.buffer,
    obj.authenticatorData.byteOffset + 33,
    4,
  ).getUint32(0);
  if (counter <= params.lastCounter) throw new Error("assert: counter replay");

  return { counter };
}
