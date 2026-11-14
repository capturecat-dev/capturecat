/**
 * The account's device link key (migration 0042, `wireless_links`).
 *
 * One random 256-bit secret per account. Every native app signed in to the
 * account fetches it (GET /api/wireless/link) and uses it as the TLS pre-shared
 * key between CaptureCat for Mac and CaptureCat for iPhone and iPad, so phones
 * and Macs on one account trust each other with no pairing step. Wire
 * contract: apps/macos/CaptureCat/Shared/WirelessDeviceProtocol.swift
 * (`WirelessLink`).
 *
 * At rest the key is AES-GCM sealed (lib/storage.ts `sealSecret`) under a key
 * HKDF-derived from STORAGE_CREDENTIALS_KEY with this file's own info label —
 * the raw storage key is never used for a second purpose — with the user id
 * bound in as additional data, so a ciphertext copied onto another account's
 * row will not open. Without that secret the feature is unavailable: a key is
 * never stored in clear.
 */

import type { Env } from "../types";
import { openSecret, sealSecret, storageCredentialsKeyBytes } from "./storage";

/** Bytes in a link key (TLS-PSK secret). Matches `WirelessLink.keyByteCount`. */
export const WIRELESS_LINK_KEY_BYTES = 32;

/** The SHA-256 prefix of the public fingerprint — `WirelessLink.keyID(for:)`. */
const KEY_ID_DOMAIN = "capturecat-wireless-link-v1";

/** HKDF info for the at-rest encryption key. Distinct from every other use of
 *  STORAGE_CREDENTIALS_KEY (bucket credentials use the raw bytes). */
const AT_REST_INFO = "capturecat-wireless-link-v1/at-rest";

export interface WirelessLink {
  /** base64url, no padding, 32 bytes. */
  key: string;
  /** 16 lowercase hex — first 8 bytes of SHA-256(domain ‖ key). */
  keyId: string;
  /** ISO-8601; when this key was minted (rotation resets it). */
  createdAt: string;
}

/** Thrown when the server has no usable STORAGE_CREDENTIALS_KEY. */
export class WirelessUnavailableError extends Error {
  constructor() {
    super("Wireless device linking is not configured on this server.");
    this.name = "WirelessUnavailableError";
  }
}

export function wirelessLinkAvailable(env: Env): boolean {
  return storageCredentialsKeyBytes(env) !== null;
}

// ---------------------------------------------------------------------------
// Encoding + fingerprint
// ---------------------------------------------------------------------------

export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64UrlDecode(value: string): Uint8Array {
  const b64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (ch) => ch.charCodeAt(0));
}

/**
 * The key's public fingerprint, exactly as `WirelessLink.keyID(for:)` computes
 * it: lowercase hex of the first 8 bytes of SHA-256("capturecat-wireless-link-v1"
 * ‖ key bytes). Advertised in the Mac's Bonjour TXT and used as the PSK
 * identity, so it must never be derivable in reverse — it isn't (SHA-256).
 */
export async function wirelessKeyId(key: Uint8Array): Promise<string> {
  const domain = new TextEncoder().encode(KEY_ID_DOMAIN);
  const input = new Uint8Array(domain.byteLength + key.byteLength);
  input.set(domain, 0);
  input.set(key, domain.byteLength);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", input));
  return Array.from(digest.subarray(0, 8), (b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------------------------------------------------------------------------
// At-rest encryption
// ---------------------------------------------------------------------------

/** Memoised per isolate on the secret's bytes (HKDF + import are cheap but
 *  not free, and every request in an isolate shares one `env`). */
let atRestKeyCache: { raw: string; key: Promise<CryptoKey> } | null = null;

function atRestKey(env: Env): Promise<CryptoKey> {
  const raw = storageCredentialsKeyBytes(env);
  if (!raw) throw new WirelessUnavailableError();
  const fingerprint = base64UrlEncode(raw);
  if (atRestKeyCache?.raw === fingerprint) return atRestKeyCache.key;
  const key = (async () => {
    const base = await crypto.subtle.importKey("raw", raw, "HKDF", false, ["deriveKey"]);
    return crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: new TextEncoder().encode(AT_REST_INFO) },
      base,
      { name: "AES-GCM", length: 256 },
      false,
      ["encrypt", "decrypt"],
    );
  })();
  atRestKeyCache = { raw: fingerprint, key };
  key.catch(() => {
    if (atRestKeyCache?.key === key) atRestKeyCache = null;
  });
  return key;
}

function aadFor(uid: string): string {
  return `wireless_links:${uid}`;
}

interface LinkRow {
  key_ciphertext: string;
  key_id: string;
  created_at: string;
}

interface SealedLink {
  ciphertext: string;
  keyId: string;
  createdAt: string;
  link: WirelessLink;
}

async function mintSealed(env: Env, uid: string): Promise<SealedLink> {
  const key = crypto.getRandomValues(new Uint8Array(WIRELESS_LINK_KEY_BYTES));
  const encoded = base64UrlEncode(key);
  const keyId = await wirelessKeyId(key);
  const createdAt = new Date().toISOString();
  const ciphertext = await sealSecret(await atRestKey(env), encoded, aadFor(uid));
  return { ciphertext, keyId, createdAt, link: { key: encoded, keyId, createdAt } };
}

/** Open a stored row; null when it can't be opened or fails its fingerprint
 *  check (the at-rest secret changed, or the row was tampered with). */
async function openRow(env: Env, uid: string, row: LinkRow): Promise<WirelessLink | null> {
  try {
    const encoded = await openSecret(await atRestKey(env), row.key_ciphertext, aadFor(uid));
    const bytes = base64UrlDecode(encoded);
    if (bytes.byteLength !== WIRELESS_LINK_KEY_BYTES) return null;
    if ((await wirelessKeyId(bytes)) !== row.key_id) return null;
    return { key: encoded, keyId: row.key_id, createdAt: row.created_at };
  } catch (err) {
    if (err instanceof WirelessUnavailableError) throw err;
    return null;
  }
}

function readRow(db: D1Database, uid: string): Promise<LinkRow | null> {
  return db
    .prepare(`SELECT key_ciphertext, key_id, created_at FROM wireless_links WHERE user_id = ?`)
    .bind(uid)
    .first<LinkRow>();
}

// ---------------------------------------------------------------------------
// Get-or-create + rotate
// ---------------------------------------------------------------------------

/**
 * The account's link, created on first use. Concurrent first calls converge on
 * ONE key: each inserts with ON CONFLICT DO NOTHING and then everyone returns
 * whatever row won.
 *
 * A row that no longer opens (STORAGE_CREDENTIALS_KEY was replaced) is
 * replaced with a fresh key by compare-and-swap on the old ciphertext, so
 * concurrent callers still converge. Devices handle that exactly like a
 * rotation: the old key fails the handshake, they refetch once and retry.
 */
export async function getOrCreateWirelessLink(env: Env, uid: string): Promise<WirelessLink> {
  if (!wirelessLinkAvailable(env)) throw new WirelessUnavailableError();

  for (let attempt = 0; attempt < 3; attempt++) {
    const row = await readRow(env.DB, uid);
    if (!row) {
      const fresh = await mintSealed(env, uid);
      await env.DB.prepare(
        `INSERT INTO wireless_links (user_id, key_ciphertext, key_id, created_at)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(user_id) DO NOTHING`,
      )
        .bind(uid, fresh.ciphertext, fresh.keyId, fresh.createdAt)
        .run();
      continue; // re-read: the winner may be another request's key
    }
    const opened = await openRow(env, uid, row);
    if (opened) return opened;

    console.error("wireless: link key could not be opened; replacing it", { uid, keyId: row.key_id });
    const fresh = await mintSealed(env, uid);
    await env.DB.prepare(
      `UPDATE wireless_links SET key_ciphertext = ?1, key_id = ?2, created_at = ?3
        WHERE user_id = ?4 AND key_ciphertext = ?5`,
    )
      .bind(fresh.ciphertext, fresh.keyId, fresh.createdAt, uid, row.key_ciphertext)
      .run();
  }
  throw new Error("wireless: could not settle the account's link key");
}

/** "Forget my devices": a fresh key replaces the account's link outright. */
export async function rotateWirelessLink(env: Env, uid: string): Promise<WirelessLink> {
  if (!wirelessLinkAvailable(env)) throw new WirelessUnavailableError();
  const fresh = await mintSealed(env, uid);
  await env.DB.prepare(
    `INSERT INTO wireless_links (user_id, key_ciphertext, key_id, created_at)
     VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT(user_id) DO UPDATE SET
       key_ciphertext = excluded.key_ciphertext,
       key_id = excluded.key_id,
       created_at = excluded.created_at`,
  )
    .bind(uid, fresh.ciphertext, fresh.keyId, fresh.createdAt)
    .run();
  return fresh.link;
}
