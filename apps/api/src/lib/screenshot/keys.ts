/**
 * Screenshot API access keys — mint, parse, verify.
 *
 * Token format:  cc_live_<id>_<secret>
 *   id      16 chars [a-z0-9], the row's PRIMARY KEY — public half.
 *   secret  48 chars [a-z0-9] (~248 bits), NEVER stored; only SHA-256(secret)
 *           lands in `screenshot_api_keys.key_hash`.
 *
 * Verification looks the row up BY ID and then constant-time-compares the
 * secret's hash against the stored hash. Looking up by hash instead would put
 * the secret-derived value into the index probe and quietly reintroduce a
 * timing channel — don't "simplify" it that way.
 *
 * PURE module (Web Crypto only) so all of it runs under plain vitest.
 */

const ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789";

function randomToken(length: number): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  let out = "";
  for (let i = 0; i < length; i++) out += ALPHABET[bytes[i] % ALPHABET.length];
  return out;
}

export const KEY_PREFIX = "cc_live_";
const ID_LENGTH = 16;
const SECRET_LENGTH = 48;

export interface MintedKey {
  id: string;
  /** Full plaintext token — returned to the caller ONCE, never stored. */
  token: string;
  /** SHA-256(secret) hex — what the D1 row stores. */
  keyHash: string;
}

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function mintKey(): Promise<MintedKey> {
  const id = randomToken(ID_LENGTH);
  const secret = randomToken(SECRET_LENGTH);
  return { id, token: `${KEY_PREFIX}${id}_${secret}`, keyHash: await sha256Hex(secret) };
}

/** Split a presented token into its lookup id + secret, or null if malformed.
 *  Malformed tokens fail fast — they can't correspond to any row. */
export function parseKeyToken(token: string): { id: string; secret: string } | null {
  if (!token.startsWith(KEY_PREFIX)) return null;
  const rest = token.slice(KEY_PREFIX.length);
  const sep = rest.indexOf("_");
  if (sep !== ID_LENGTH) return null;
  const id = rest.slice(0, sep);
  const secret = rest.slice(sep + 1);
  if (secret.length !== SECRET_LENGTH) return null;
  if (!/^[a-z0-9]+$/.test(id) || !/^[a-z0-9]+$/.test(secret)) return null;
  return { id, secret };
}

/**
 * Constant-time string equality. Implemented as an XOR fold rather than
 * `crypto.subtle.timingSafeEqual` because the latter is Workers-only and this
 * must also run under Node vitest. Length mismatch returns false without
 * early-exiting the loop over the shorter string.
 */
export function timingSafeEqual(a: string, b: string): boolean {
  const len = Math.max(a.length, b.length);
  let diff = a.length ^ b.length;
  for (let i = 0; i < len; i++) {
    diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return diff === 0;
}

/** True when the presented secret matches the stored hash. */
export async function verifySecret(secret: string, storedHash: string): Promise<boolean> {
  return timingSafeEqual(await sha256Hex(secret), storedHash);
}
