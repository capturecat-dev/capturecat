/**
 * Share-link policy shared by the session routes (routes/video.ts) and the
 * remote MCP server (src/mcp/): who may view a video, how share-page
 * controls are validated, and how share passwords are hashed. One copy, so
 * an agent can never set a control the dashboard could not, or see a video
 * the dashboard would not show.
 */

import type { Env, VideoMetadata } from "../types";
import { isOrgMember, updateShareControls } from "./db";
import { planForUser } from "./entitlement";

// ---------------------------------------------------------------------------
// Who may view a video
// ---------------------------------------------------------------------------

/**
 * Owner-level VIEW access: the uploader, or a member of the video's org while
 * the UPLOADER's plan still includes teams — checked at view time, so one
 * month of a paid plan never buys a permanent private team library.
 * Mutations stay uploader-only in their own routes.
 */
export async function canViewVideo(env: { DB: D1Database }, doc: VideoMetadata, uid: string): Promise<boolean> {
  if (uid === doc.uid) return true;
  if (doc.orgId) {
    if (!(await isOrgMember(env.DB, doc.orgId, uid))) return false;
    return (await planForUser(env, doc.uid)).features.teams;
  }
  return false;
}

/** Drop the byte route's per-colo metadata cache entry. MANDATORY after any
 *  change to privacy or a share gate — the byte route decides on that copy. */
export async function purgeVideoMeta(videoId: string): Promise<void> {
  await caches.default.delete(new Request(`https://meta.internal/video/${videoId}`));
}

// ---------------------------------------------------------------------------
// Share passwords
// ---------------------------------------------------------------------------

export function toHex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Legacy (pre-hardening) form: SHA-256("<videoId>:<password>") hex. Only
 *  used to VERIFY old rows, which are re-hashed on first successful unlock. */
async function legacyPasswordDigest(videoId: string, password: string): Promise<string> {
  const data = new TextEncoder().encode(`${videoId}:${password}`);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return toHex(new Uint8Array(hash));
}

const PBKDF2_ITERATIONS = 210_000;

async function pbkdf2(password: string, salt: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt, iterations: PBKDF2_ITERATIONS }, key, 256
  );
  return toHex(new Uint8Array(bits));
}

/** Stored form: `pbkdf2$<saltHex>$<hashHex>` — salted, 210k iterations, so a
 *  leaked table is not crackable at GPU speed the way a single SHA-256 was. */
export async function passwordDigest(_videoId: string, password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  return `pbkdf2$${toHex(salt)}$${await pbkdf2(password, salt)}`;
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Verify against either form; returns whether the stored hash is legacy so
 *  the caller can upgrade it. */
export async function verifyPassword(
  videoId: string, password: string, stored: string
): Promise<{ ok: boolean; legacy: boolean }> {
  const parts = stored.split("$");
  if (parts.length === 3 && parts[0] === "pbkdf2") {
    const salt = new Uint8Array(parts[1].match(/.{2}/g)!.map((h) => parseInt(h, 16)));
    return { ok: constantTimeEqual(await pbkdf2(password, salt), parts[2]), legacy: false };
  }
  return { ok: constantTimeEqual(await legacyPasswordDigest(videoId, password), stored), legacy: true };
}

// ---------------------------------------------------------------------------
// Share-page controls (migration 0012 and later)
// ---------------------------------------------------------------------------

export type ShareControlsPatch = Parameters<typeof updateShareControls>[2];

/** The share-page controls a body may set — PATCH /video/:id/settings's
 *  body, and the MCP update_share_settings tool after it renames its input. */
export interface ShareControlsBody {
  allowDownload?: unknown;
  password?: unknown;
  expiresAt?: unknown;
  maxViews?: unknown;
  brandAccent?: unknown;
  showVersionHistory?: unknown;
  ctaLabel?: unknown;
  ctaUrl?: unknown;
  profileVisible?: unknown;
}

/**
 * Body → the columns to write. Lenient by design (the dashboard sends only
 * what changed): a field that is absent or invalid is simply left out, and
 * an empty patch is the caller's 400. `null` clears where clearing exists.
 * The password is hashed here; plaintext never reaches the data layer.
 */
export async function shareControlsPatch(videoId: string, body: ShareControlsBody): Promise<ShareControlsPatch> {
  const patch: ShareControlsPatch = {};
  if (typeof body.allowDownload === "boolean") patch.allowDownload = body.allowDownload;
  if (body.password === null) patch.passwordHash = null;
  else if (typeof body.password === "string" && body.password.length >= 1) {
    patch.passwordHash = await passwordDigest(videoId, body.password.slice(0, 100));
  }
  if (body.expiresAt === null) patch.expiresAt = null;
  else if (typeof body.expiresAt === "string" && !isNaN(Date.parse(body.expiresAt))) {
    patch.expiresAt = new Date(body.expiresAt).toISOString();
  }
  if (body.maxViews === null) patch.maxViews = null;
  else if (typeof body.maxViews === "number" && body.maxViews >= 0) {
    patch.maxViews = Math.floor(Math.min(body.maxViews, 1_000_000));
  }
  if (body.brandAccent === null) patch.brandAccent = null;
  else if (typeof body.brandAccent === "string" && /^#[0-9a-fA-F]{6}$/.test(body.brandAccent)) {
    patch.brandAccent = body.brandAccent.toUpperCase();
  }
  if (typeof body.showVersionHistory === "boolean") {
    patch.showVersionHistory = body.showVersionHistory;
  }
  if (typeof body.profileVisible === "boolean") {
    patch.profileVisible = body.profileVisible;
  }
  // CTA button: label + https URL set together; null clears both. The URL is
  // owner-supplied and rendered as a link on a public page — https only, and
  // re-parsed here rather than trusted.
  if (body.ctaLabel === null || body.ctaUrl === null) {
    patch.ctaLabel = null;
    patch.ctaUrl = null;
  } else if (typeof body.ctaLabel === "string" && typeof body.ctaUrl === "string") {
    const label = body.ctaLabel.trim().slice(0, 60);
    const ctaUrl = body.ctaUrl;
    const parsed = (() => {
      try { return new URL(ctaUrl.trim()); } catch { return null; }
    })();
    if (label && parsed && parsed.protocol === "https:" && ctaUrl.length <= 300) {
      patch.ctaLabel = label;
      patch.ctaUrl = parsed.toString();
    }
  }
  return patch;
}

/** Apply a non-empty patch and purge the metadata cache. False = no row. */
export async function applyShareControls(env: Pick<Env, "DB">, videoId: string, patch: ShareControlsPatch): Promise<boolean> {
  const changed = await updateShareControls(env.DB, videoId, patch);
  if (changed) await purgeVideoMeta(videoId);
  return changed;
}
