import { Hono } from "hono";
import type { Env, Variables } from "../types";
import {
  countVideoComments,
  deleteVideoVersion,
  getSharedVideo,
  getVideoVersion,
  insertVideoComment,
  listSharedVideos,
  listVideoComments,
  listVideoVersions,
  setCurrentVersion,
  setSharedVideoPrivacy,
  setThumbnailType,
  storageUsageBytes,
  updateShareControls,
  viewCount,
} from "../lib/db";
import type { VideoMetadata } from "../types";
import { getAISummary, getTranscript } from "../lib/db";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement, userRateLimit, fixedWindowAllow } from "../lib/entitlement";
import { generateId } from "../lib/id";
import { PRO_PLAN_LIMITS } from "../lib/stripe";
import { shareBaseURL } from "../lib/origins";

export const videoRoutes = new Hono<{
  Bindings: Env;
  Variables: Variables;
}>();

/**
 * GET /video/:videoId
 * Stream video from R2 with HTTP Range support.
 * Checks the `isPrivate` flag — private videos require auth.
 */
videoRoutes.get("/video/:videoId", async (c) => {
  const videoId = c.req.param("videoId");

  // Check cache first to avoid DB reads on every request
  const cache = caches.default;
  const metaCacheKey = new Request(`https://meta.internal/video/${videoId}`);
  let doc: VideoMetadata | null = null;

  const cachedMeta = await cache.match(metaCacheKey);
  if (cachedMeta) {
    doc = await cachedMeta.json();
  } else {
    doc = await getSharedVideo(c.env.DB, videoId);

    // Short metadata cache: purges are per-colo, so a settings change
    // (privacy, password, expiry) must go stale everywhere within seconds,
    // not five minutes.
    if (doc && doc.status === "ready") {
      await cache.put(
        metaCacheKey,
        new Response(JSON.stringify(doc), {
          headers: { "Cache-Control": "s-maxage=30" },
        })
      );
    }
  }

  if (!doc || doc.status !== "ready") {
    return c.json({ error: "Video not found" }, 404);
  }

  // Metadata cached before the 0017 deploy predates these fields.
  doc.currentVersion ??= 1;
  doc.showVersionHistory ??= false;

  // Check privacy — if private, require auth header with matching uid
  if (doc.isPrivate) {
    if (!(await isOwnerRequest(c, doc))) {
      return c.json({ error: "This video is private" }, 403);
    }
  }

  // Share gates (password/expiry/view-cap). The owner streaming their own
  // private video already passed the auth branch above; public viewers carry
  // the unlock token as a query param (video element src can't set headers).
  if (!doc.isPrivate) {
    const gate = await shareGate(c, doc, c.req.query("token"));
    if (gate.state === "locked") return c.json({ error: "Password required" }, 403);
    if (gate.state === "expired") return c.json({ error: "This link has expired" }, 410);
    if (gate.state === "view_limit") return c.json({ error: "View limit reached" }, 403);
  }

  // Version pinning (migration 0017). `?v=N` streams a specific version —
  // any ready version when the owner exposed history, otherwise only the
  // current one (or anything, for the owner). No `?v` streams the current
  // version, whatever it is today.
  let r2Key = doc.r2Key;
  const vParam = c.req.query("v");
  const pinnedVersion = vParam !== undefined ? parseInt(vParam, 10) : null;
  if (vParam !== undefined) {
    if (!Number.isInteger(pinnedVersion) || pinnedVersion! < 1) {
      return c.json({ error: "Invalid version" }, 400);
    }
    if (pinnedVersion !== doc.currentVersion) {
      if (!doc.showVersionHistory && !(await isOwnerRequest(c, doc))) {
        return c.json({ error: "Version history is not available" }, 403);
      }
      const version = await getVideoVersion(c.env.DB, videoId, pinnedVersion!);
      if (!version || version.status !== "ready") {
        return c.json({ error: "Version not found" }, 404);
      }
      r2Key = version.r2Key;
    }
  }

  const rangeHeader = c.req.header("Range");
  // Gated videos must not land in the shared edge cache — the cache key is
  // the URL and a cached copy would outlive the gate.
  const isPublic = !doc.isPrivate && !doc.passwordHash && !doc.maxViews && !doc.expiresAt;

  // For public videos, check Cloudflare CDN cache first
  if (isPublic) {
    const cachedResponse = await cache.match(c.req.raw);
    if (cachedResponse) {
      return cachedResponse;
    }
  }

  // Fetch from R2 with optional range
  const object = rangeHeader
    ? await c.env.R2.get(r2Key, { range: parseRange(rangeHeader) })
    : await c.env.R2.get(r2Key);

  if (!object) {
    return c.json({ error: "Video file not found in storage" }, 404);
  }
  // The presigned PUT outlives /complete; only the bytes verified there are
  // served under this record.
  if (doc.etag && r2Key === doc.r2Key && object.etag !== doc.etag) {
    return c.json({ error: "Video file not found in storage" }, 404);
  }

  const contentType = doc.contentType || "video/mp4";
  const headers = new Headers();
  headers.set("Content-Type", contentType);
  headers.set("Accept-Ranges", "bytes");
  // A URL that pins a version (?v=N) really is immutable — a version's bytes
  // never change. The bare URL follows current_version, which a replace
  // upload can flip at any time, so it must not be cached for a year.
  headers.set(
    "Cache-Control",
    !isPublic
      ? "private, no-store"
      : pinnedVersion !== null
        ? "public, max-age=31536000, immutable"
        : "public, max-age=300"
  );

  let response: Response;

  if (rangeHeader && "range" in object) {
    const { offset, length } = object.range as { offset: number; length: number };
    const totalSize = object.size;
    headers.set(
      "Content-Range",
      `bytes ${offset}-${offset + length - 1}/${totalSize}`
    );
    headers.set("Content-Length", String(length));

    response = new Response(object.body, { status: 206, headers });
  } else {
    headers.set("Content-Length", String(object.size));
    response = new Response(object.body, { status: 200, headers });
  }

  // Cache public video responses at Cloudflare edge. Only full 200 responses:
  // the Cache API rejects 206 Partial Content with an uncaught TypeError, and
  // a ranged request must not poison the cache entry for the bare URL anyway.
  if (isPublic && response.status === 200) {
    c.executionCtx.waitUntil(cache.put(c.req.raw, response.clone()));
  }

  return response;
});

/** Whether the request carries a Bearer session belonging to the video's
 *  owner. Lazy-imports the auth instance so public streams never build it. */
async function isOwnerRequest(
  c: { env: Env; req: { header(name: string): string | undefined; raw: Request } },
  doc: VideoMetadata
): Promise<boolean> {
  const authHeader = c.req.header("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return false;
  const { getAuth } = await import("../lib/auth");
  try {
    const session = await getAuth(c.env).api.getSession({
      headers: c.req.raw.headers,
    });
    if (!session) return false;
    if (session.user.id === doc.uid) return true;
    // Team library: members of the video's org get owner-level VIEW access
    // (mutations stay uploader-scoped in their own routes).
    if (doc.orgId) {
      const { isOrgMember } = await import("../lib/db");
      return isOrgMember(c.env.DB, doc.orgId, session.user.id);
    }
    return false;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Share gates: password / expiry / view cap (migration 0012)
// ---------------------------------------------------------------------------

/** Legacy (pre-hardening) form: SHA-256("<videoId>:<password>") hex. Only
 *  used to VERIFY old rows, which are re-hashed on first successful unlock. */
async function legacyPasswordDigest(videoId: string, password: string): Promise<string> {
  const data = new TextEncoder().encode(`${videoId}:${password}`);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return toHex(new Uint8Array(hash));
}

function toHex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
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
async function passwordDigest(_videoId: string, password: string): Promise<string> {
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
async function verifyPassword(
  videoId: string, password: string, stored: string
): Promise<{ ok: boolean; legacy: boolean }> {
  const parts = stored.split("$");
  if (parts.length === 3 && parts[0] === "pbkdf2") {
    const salt = new Uint8Array(parts[1].match(/.{2}/g)!.map((h) => parseInt(h, 16)));
    return { ok: constantTimeEqual(await pbkdf2(password, salt), parts[2]), legacy: false };
  }
  return { ok: constantTimeEqual(await legacyPasswordDigest(videoId, password), stored), legacy: true };
}

/** Unlock tokens: HMAC(secret, "unlock:<videoId>:<hourBucket>") hex. Valid for
 *  the current and previous hour, so a token lives 1–2 hours. Stateless — no
 *  row writes, nothing to revoke beyond changing the password (which changes
 *  nothing here, deliberately: tokens gate the *page session*, the password
 *  gates new visitors). */
async function unlockToken(env: Env, videoId: string, bucket: number): Promise<string> {
  // Purpose-derived key (HMAC(secret, "share-unlock")) rather than the raw
  // auth secret, so unlock tokens and session material are cryptographically
  // unrelated: leaking one says nothing about the other, and either can be
  // rotated independently.
  const root = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(env.BETTER_AUTH_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const derived = await crypto.subtle.sign(
    "HMAC", root, new TextEncoder().encode("share-unlock")
  );
  const key = await crypto.subtle.importKey(
    "raw", derived, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const mac = await crypto.subtle.sign(
    "HMAC", key, new TextEncoder().encode(`unlock:${videoId}:${bucket}`)
  );
  return toHex(new Uint8Array(mac));
}

export async function isValidUnlockToken(env: Env, videoId: string, token: string | undefined): Promise<boolean> {
  if (!token) return false;
  const bucket = Math.floor(Date.now() / 3_600_000);
  for (const b of [bucket, bucket - 1]) {
    if ((await unlockToken(env, videoId, b)) === token) return true;
  }
  return false;
}

type ShareGate =
  | { state: "open" }
  | { state: "locked" }
  | { state: "expired" }
  | { state: "view_limit" };

/** The share-page gate, shared by /meta, the byte route, and /download so the
 *  page and the stream can never disagree. */
async function shareGate(
  c: { env: Env },
  doc: VideoMetadata,
  token: string | undefined
): Promise<ShareGate> {
  if (doc.expiresAt && Date.parse(doc.expiresAt) < Date.now()) {
    return { state: "expired" };
  }
  if (doc.maxViews && doc.maxViews > 0) {
    if ((await viewCount(c.env.DB, doc.videoId)) >= doc.maxViews) {
      // Sessions that already registered keep watching (their view row
      // exists); new sessions are refused at the page.
      return { state: "view_limit" };
    }
  }
  if (doc.passwordHash) {
    if (!(await isValidUnlockToken(c.env, doc.videoId, token))) {
      return { state: "locked" };
    }
  }
  return { state: "open" };
}

// POST /video/:videoId/unlock — exchange the password for a share token.
videoRoutes.post("/video/:videoId/unlock", async (c) => {
  const doc = await getSharedVideo(c.env.DB, c.req.param("videoId"));
  if (!doc || doc.status !== "ready" || doc.isPrivate) {
    return c.json({ error: "Video not found" }, 404);
  }
  if (!doc.passwordHash) return c.json({ error: "Not password protected" }, 400);

  // Small fixed per-IP budget — password guessing is the whole threat model.
  const ip = c.req.header("CF-Connecting-IP") ?? "unknown";
  const windowKey = Math.floor(Date.now() / 600_000);
  const rateKey = new Request(
    `https://rate-limit.internal/unlock/${encodeURIComponent(ip)}/${doc.videoId}/${windowKey}`
  );
  const cached = await caches.default.match(rateKey);
  const attempts = cached ? parseInt(await cached.text(), 10) : 0;
  if (attempts >= 10) return c.json({ error: "Too many attempts" }, 429);
  await caches.default.put(
    rateKey,
    new Response(String(attempts + 1), { headers: { "Cache-Control": "s-maxage=600" } })
  );
  // Global inner layer: the cache counter above is per-colo, so a distributed
  // guesser would otherwise get 10 attempts × every edge location.
  if (!(await fixedWindowAllow(c.env.DB, `unlock:${doc.videoId}:${ip}`, 10, 600))) {
    return c.json({ error: "Too many attempts" }, 429);
  }

  const body: { password?: unknown } = await c.req.json().catch(() => ({}));
  if (typeof body.password !== "string" || body.password.length === 0) {
    return c.json({ error: "password required" }, 400);
  }
  const verdict = await verifyPassword(doc.videoId, body.password, doc.passwordHash);
  if (!verdict.ok) return c.json({ error: "Wrong password" }, 403);
  if (verdict.legacy) {
    // Transparent upgrade of a pre-hardening row to the salted form.
    await c.env.DB.prepare("UPDATE shared_videos SET password_hash = ? WHERE video_id = ?")
      .bind(await passwordDigest(doc.videoId, body.password), doc.videoId)
      .run();
  }

  const bucket = Math.floor(Date.now() / 3_600_000);
  return c.json({ token: await unlockToken(c.env, doc.videoId, bucket) });
});

/**
 * Parse an HTTP Range header into R2 range options.
 * Supports "bytes=start-end" and "bytes=start-" formats.
 */
function parseRange(
  rangeHeader: string
): { offset: number; length?: number } | { suffix: number } {
  const match = rangeHeader.match(/^bytes=(\d+)-(\d*)$/);
  if (!match) {
    return { offset: 0 };
  }

  const start = parseInt(match[1], 10);
  if (match[2]) {
    const end = parseInt(match[2], 10);
    // "bytes=10-5" → negative length → R2 throws → 500. Treat as no range.
    if (end < start) return { offset: 0 };
    return { offset: start, length: end - start + 1 };
  }

  return { offset: start };
}


// ---------------------------------------------------------------------------
// GET /video/:videoId/meta — public metadata for the share page
// ---------------------------------------------------------------------------
/**
 * Applies the IDENTICAL `ready && !isPrivate` gate the byte route uses, so the
 * page and the stream can never disagree — a page that renders for a video the
 * stream then refuses is worse than a clean 404.
 *
 * Deliberately omits `uid` and `r2Key`. The share page previously read the raw
 * Firestore document and pulled both into the rendered page.
 */
videoRoutes.get("/video/:videoId/meta", async (c) => {
  const doc = await getSharedVideo(c.env.DB, c.req.param("videoId"));
  if (!doc || doc.status !== "ready" || doc.isPrivate) {
    return c.json({ error: "Video not found" }, 404);
  }
  const gate = await shareGate(c, doc, c.req.query("token"));
  if (gate.state !== "open") {
    // The page needs to know WHICH wall it hit to render the right state,
    // but a gated video leaks nothing beyond its title.
    return c.json({
      videoId: doc.videoId,
      fileName: doc.fileName,
      gate: gate.state,
      brandAccent: doc.brandAccent,
    });
  }
  const [ai, transcript] = await Promise.all([
    getAISummary(c.env.DB, doc.videoId),
    getTranscript(c.env.DB, doc.videoId),
  ]);
  let aiChapters: unknown[] = [];
  if (ai?.chaptersJson) {
    try {
      const parsed = JSON.parse(ai.chaptersJson);
      if (Array.isArray(parsed)) aiChapters = parsed;
    } catch { /* ignore */ }
  }
  return c.json({
    videoId: doc.videoId,
    fileName: doc.fileName,
    contentType: doc.contentType,
    fileSizeBytes: doc.fileSizeBytes,
    durationSeconds: doc.durationSeconds,
    createdAt: doc.createdAt,
    commentsEnabled: doc.commentsEnabled,
    allowDownload: doc.allowDownload,
    brandAccent: doc.brandAccent,
    gate: "open",
    aiTitle: ai?.title ?? null,
    aiSummary: ai?.summary ?? null,
    aiChapters,
    hasTranscript: (transcript?.length ?? 0) > 0,
    // Parsed here so the page never has to trust a raw JSON string.
    annotations: parseMarkers(doc.annotationsJson),
    currentVersion: doc.currentVersion ?? 1,
    showVersionHistory: doc.showVersionHistory === true,
    ctaLabel: doc.ctaLabel ?? null,
    ctaUrl: doc.ctaUrl ?? null,
    // Absolute URL so the share page (and its OG image) can use it directly.
    thumbnailUrl: doc.thumbnailType
      ? `${new URL(c.env.BETTER_AUTH_URL).origin}/api/video/${doc.videoId}/thumbnail`
      : null,
    // Only populated when the owner opted in — viewers can pick an older
    // version to play (?v=N on the stream URL).
    versions:
      doc.showVersionHistory === true
        ? (await listVideoVersions(c.env.DB, doc.videoId, true)).map((v) => ({
            version: v.versionNumber,
            createdAt: v.createdAt,
            durationSeconds: v.durationSeconds,
            current: v.versionNumber === (doc.currentVersion ?? 1),
          }))
        : [],
  });
});

// ---------------------------------------------------------------------------
// GET /video/:videoId/download — original file, attachment disposition
// ---------------------------------------------------------------------------
videoRoutes.get("/video/:videoId/download", async (c) => {
  const doc = await getSharedVideo(c.env.DB, c.req.param("videoId"));
  if (!doc || doc.status !== "ready" || doc.isPrivate || !doc.allowDownload) {
    return c.json({ error: "Download unavailable" }, 404);
  }
  const gate = await shareGate(c, doc, c.req.query("token"));
  if (gate.state !== "open") return c.json({ error: "Download unavailable" }, 403);

  const object = await c.env.R2.get(doc.r2Key);
  if (!object) return c.json({ error: "Video file not found in storage" }, 404);

  const safeName = doc.fileName.replace(/[^\w.\- ]/g, "_") || "video.mp4";
  const headers = new Headers();
  headers.set("Content-Type", doc.contentType || "video/mp4");
  headers.set("Content-Length", String(object.size));
  headers.set("Content-Disposition", `attachment; filename="${safeName}"`);
  return new Response(object.body, { status: 200, headers });
});

// ---------------------------------------------------------------------------
// PATCH /video/:videoId/settings — owner share-page controls
// ---------------------------------------------------------------------------
videoRoutes.patch("/video/:videoId/settings", requireAuth, requireEntitlement(), async (c) => {
  const videoId = c.req.param("videoId");
  const doc = await getSharedVideo(c.env.DB, videoId);
  if (!doc) return c.json({ error: "Video not found" }, 404);
  if (doc.uid !== c.get("user").uid) return c.json({ error: "Forbidden" }, 403);

  const body: {
    allowDownload?: unknown;
    password?: unknown;
    expiresAt?: unknown;
    maxViews?: unknown;
    brandAccent?: unknown;
    showVersionHistory?: unknown;
    ctaLabel?: unknown;
    ctaUrl?: unknown;
    profileVisible?: unknown;
  } = await c.req.json().catch(() => ({}));

  const patch: Parameters<typeof updateShareControls>[2] = {};
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
    const parsed = (() => {
      try { return new URL(body.ctaUrl.trim()); } catch { return null; }
    })();
    if (label && parsed && parsed.protocol === "https:" && body.ctaUrl.length <= 300) {
      patch.ctaLabel = label;
      patch.ctaUrl = parsed.toString();
    }
  }

  if (Object.keys(patch).length === 0) {
    return c.json({ error: "No valid fields" }, 400);
  }
  const changed = await updateShareControls(c.env.DB, videoId, patch);
  if (!changed) return c.json({ error: "Video not found" }, 404);

  // Same mandatory purge as the privacy toggle — the byte route's metadata
  // cache would otherwise serve the OLD gates for up to five minutes.
  await caches.default.delete(new Request(`https://meta.internal/video/${videoId}`));

  return c.json({ videoId, updated: Object.keys(patch) });
});

function parseMarkers(json: string | null): unknown[] {
  if (!json) return [];
  try {
    const parsed = JSON.parse(json);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// Viewer comments — public read/write, gated on the uploader's opt-in
// ---------------------------------------------------------------------------

/** Same visibility gate as /meta: ready, public, and comments switched on. */
async function commentableVideo(db: D1Database, videoId: string) {
  const doc = await getSharedVideo(db, videoId);
  if (!doc || doc.status !== "ready" || doc.isPrivate || !doc.commentsEnabled) {
    return null;
  }
  return doc;
}

videoRoutes.get("/video/:videoId/comments", async (c) => {
  const doc = await commentableVideo(c.env.DB, c.req.param("videoId"));
  if (!doc) return c.json({ error: "Comments unavailable" }, 404);
  const comments = await listVideoComments(c.env.DB, doc.videoId);
  return c.json({
    comments: comments.map((cm) => ({
      commentId: cm.commentId,
      authorName: cm.authorName,
      body: cm.body,
      videoTime: cm.videoTime,
      createdAt: cm.createdAt,
    })),
  });
});

/** Max comments a single video accepts — runaway-thread backstop. */
const MAX_COMMENTS_PER_VIDEO = 500;
/** Posts allowed per IP per 10 minutes. */
const COMMENT_RATE_LIMIT = 10;

videoRoutes.post("/video/:videoId/comments", async (c) => {
  const doc = await commentableVideo(c.env.DB, c.req.param("videoId"));
  if (!doc) return c.json({ error: "Comments unavailable" }, 404);

  // Per-IP window via the edge cache, mirroring the daily-upload counter.
  const ip = c.req.header("CF-Connecting-IP") ?? "unknown";
  const windowKey = Math.floor(Date.now() / 600_000);
  const rateKey = new Request(
    `https://rate-limit.internal/comment/${encodeURIComponent(ip)}/${windowKey}`
  );
  const cache = caches.default;
  const cached = await cache.match(rateKey);
  const count = cached ? parseInt(await cached.text(), 10) : 0;
  if (count >= COMMENT_RATE_LIMIT) {
    return c.json({ error: "Slow down — try again in a few minutes" }, 429);
  }
  await cache.put(
    rateKey,
    new Response(String(count + 1), {
      headers: { "Cache-Control": "s-maxage=600" },
    })
  );
  // Global inner layer — see the unlock route.
  if (!(await fixedWindowAllow(c.env.DB, `comment:${ip}`, COMMENT_RATE_LIMIT, 600))) {
    return c.json({ error: "Slow down — try again in a few minutes" }, 429);
  }

  if ((await countVideoComments(c.env.DB, doc.videoId)) >= MAX_COMMENTS_PER_VIDEO) {
    return c.json({ error: "This video is no longer accepting comments" }, 403);
  }

  const body: { authorName?: unknown; body?: unknown; videoTime?: unknown } =
    await c.req
      .json<{ authorName?: unknown; body?: unknown; videoTime?: unknown }>()
      .catch(() => ({}));

  const text = typeof body.body === "string" ? body.body.trim() : "";
  if (!text || text.length > 500) {
    return c.json({ error: "Comment must be 1–500 characters" }, 400);
  }
  const author =
    typeof body.authorName === "string" && body.authorName.trim()
      ? body.authorName.trim().slice(0, 40)
      : "Anonymous";
  const rawTime =
    typeof body.videoTime === "number" && isFinite(body.videoTime)
      ? body.videoTime
      : 0;
  const videoTime =
    Math.round(
      Math.min(Math.max(0, rawTime), Math.max(0, doc.durationSeconds)) * 1000
    ) / 1000;

  const comment = {
    commentId: generateId(),
    videoId: doc.videoId,
    authorName: author,
    body: text,
    videoTime,
    createdAt: new Date().toISOString(),
  };
  await insertVideoComment(c.env.DB, comment);

  return c.json({
    comment: {
      commentId: comment.commentId,
      authorName: comment.authorName,
      body: comment.body,
      videoTime: comment.videoTime,
      createdAt: comment.createdAt,
    },
  });
});

// ---------------------------------------------------------------------------
// Version history — owner management (migration 0017)
// ---------------------------------------------------------------------------

/** GET /video/:videoId/versions — every version, newest first. Owner only:
 *  sizes and pending rows are library data, not share-page data. */
videoRoutes.get("/video/:videoId/versions", requireAuth, requireEntitlement(), async (c) => {
  const doc = await getSharedVideo(c.env.DB, c.req.param("videoId"));
  if (!doc) return c.json({ error: "Video not found" }, 404);
  if (doc.uid !== c.get("user").uid) return c.json({ error: "Forbidden" }, 403);

  const versions = await listVideoVersions(c.env.DB, doc.videoId);
  return c.json({
    videoId: doc.videoId,
    currentVersion: doc.currentVersion,
    showVersionHistory: doc.showVersionHistory,
    versions: versions.map((v) => ({
      version: v.versionNumber,
      fileSizeBytes: v.fileSizeBytes,
      durationSeconds: v.durationSeconds,
      status: v.status,
      createdAt: v.createdAt,
      current: v.versionNumber === doc.currentVersion,
    })),
  });
});

/** POST /video/:videoId/versions/:version/restore — point the share link at
 *  an older version. The newer files stay in history. */
videoRoutes.post(
  "/video/:videoId/versions/:version/restore",
  requireAuth,
  requireEntitlement(),
  async (c) => {
    const videoId = c.req.param("videoId");
    const versionNumber = parseInt(c.req.param("version"), 10);
    if (!Number.isInteger(versionNumber) || versionNumber < 1) {
      return c.json({ error: "Invalid version" }, 400);
    }

    const doc = await getSharedVideo(c.env.DB, videoId);
    if (!doc) return c.json({ error: "Video not found" }, 404);
    if (doc.uid !== c.get("user").uid) return c.json({ error: "Forbidden" }, 403);

    const version = await getVideoVersion(c.env.DB, videoId, versionNumber);
    if (!version || version.status !== "ready") {
      return c.json({ error: "Version not found" }, 404);
    }

    await setCurrentVersion(c.env.DB, videoId, version);
    // Byte route gates on the 5-minute metadata cache — purge so the link
    // plays the restored version now.
    await caches.default.delete(new Request(`https://meta.internal/video/${videoId}`));

    return c.json({ videoId, currentVersion: versionNumber });
  }
);

/** DELETE /video/:videoId/versions/:version — drop one historical file.
 *  The current version is protected; delete the whole video instead. */
videoRoutes.delete(
  "/video/:videoId/versions/:version",
  requireAuth,
  requireEntitlement(),
  async (c) => {
    const videoId = c.req.param("videoId");
    const versionNumber = parseInt(c.req.param("version"), 10);
    if (!Number.isInteger(versionNumber) || versionNumber < 1) {
      return c.json({ error: "Invalid version" }, 400);
    }

    const doc = await getSharedVideo(c.env.DB, videoId);
    if (!doc) return c.json({ error: "Video not found" }, 404);
    if (doc.uid !== c.get("user").uid) return c.json({ error: "Forbidden" }, 403);
    if (versionNumber === doc.currentVersion) {
      return c.json({ error: "Cannot delete the live version" }, 400);
    }

    const version = await getVideoVersion(c.env.DB, videoId, versionNumber);
    if (!version) return c.json({ error: "Version not found" }, 404);

    // Never delete an object another version row still points at (the v1
    // backfill and the live row can share videos/{id}.mp4).
    const others = (await listVideoVersions(c.env.DB, videoId)).filter(
      (v) => v.versionNumber !== versionNumber
    );
    const keyStillUsed =
      doc.r2Key === version.r2Key || others.some((v) => v.r2Key === version.r2Key);
    if (!keyStillUsed) {
      await c.env.R2.delete(version.r2Key);
    }
    await deleteVideoVersion(c.env.DB, videoId, versionNumber);

    return c.json({ videoId, deletedVersion: versionNumber });
  }
);

// ---------------------------------------------------------------------------
// Custom thumbnails (migration 0020) — owner-uploaded poster image in R2 at
// `thumbs/{videoId}`, existence recorded in shared_videos.thumbnail_type.
// ---------------------------------------------------------------------------

const THUMBNAIL_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
const THUMBNAIL_MAX_BYTES = 5 * 1024 * 1024;

const thumbnailR2Key = (videoId: string) => `thumbs/${videoId}`;

/** Purge both edge-cached views of a thumbnail change: the metadata cache the
 *  byte/meta routes gate on, and the cached GET /thumbnail response itself. */
async function purgeThumbnailCaches(env: Env, videoId: string): Promise<void> {
  const origin = new URL(env.BETTER_AUTH_URL).origin;
  await Promise.all([
    caches.default.delete(new Request(`https://meta.internal/video/${videoId}`)),
    caches.default.delete(new Request(`${origin}/api/video/${videoId}/thumbnail`)),
  ]);
}

/** PUT /video/:videoId/thumbnail — raw image body, owner only. */
videoRoutes.put(
  "/video/:videoId/thumbnail",
  requireAuth,
  requireEntitlement(),
  userRateLimit({ limit: 30, windowSec: 60, scope: "thumbnail" }),
  async (c) => {
    const videoId = c.req.param("videoId");
    const doc = await getSharedVideo(c.env.DB, videoId);
    if (!doc) return c.json({ error: "Video not found" }, 404);
    if (doc.uid !== c.get("user").uid) return c.json({ error: "Forbidden" }, 403);

    const contentType = (c.req.header("Content-Type") ?? "").split(";")[0].trim().toLowerCase();
    if (!THUMBNAIL_TYPES.has(contentType)) {
      return c.json({ error: "Thumbnail must be image/jpeg, image/png or image/webp" }, 415);
    }
    // Cheap early refusal when the client declares its size…
    const declared = parseInt(c.req.header("Content-Length") ?? "", 10);
    if (Number.isFinite(declared) && declared > THUMBNAIL_MAX_BYTES) {
      return c.json({ error: "Thumbnail must be 5 MB or smaller" }, 413);
    }
    // …and the authoritative check on the actual bytes.
    const body = await c.req.arrayBuffer();
    if (body.byteLength === 0) return c.json({ error: "Empty body" }, 400);
    if (body.byteLength > THUMBNAIL_MAX_BYTES) {
      return c.json({ error: "Thumbnail must be 5 MB or smaller" }, 413);
    }

    await c.env.R2.put(thumbnailR2Key(videoId), body, {
      httpMetadata: { contentType },
    });
    await setThumbnailType(c.env.DB, videoId, contentType);
    await purgeThumbnailCaches(c.env, videoId);

    return c.json({ videoId, thumbnailType: contentType });
  }
);

/** DELETE /video/:videoId/thumbnail — back to the decoded-frame fallback. */
videoRoutes.delete(
  "/video/:videoId/thumbnail",
  requireAuth,
  requireEntitlement(),
  userRateLimit({ limit: 30, windowSec: 60, scope: "thumbnail" }),
  async (c) => {
    const videoId = c.req.param("videoId");
    const doc = await getSharedVideo(c.env.DB, videoId);
    if (!doc) return c.json({ error: "Video not found" }, 404);
    if (doc.uid !== c.get("user").uid) return c.json({ error: "Forbidden" }, 403);

    await c.env.R2.delete(thumbnailR2Key(videoId));
    await setThumbnailType(c.env.DB, videoId, null);
    await purgeThumbnailCaches(c.env, videoId);

    return c.json({ videoId, thumbnailType: null });
  }
);

/** GET /video/:videoId/thumbnail — the image bytes. Same visibility rules as
 *  the byte route: private → owner only; share gates apply to public videos. */
videoRoutes.get("/video/:videoId/thumbnail", async (c) => {
  const videoId = c.req.param("videoId");
  const doc = await getSharedVideo(c.env.DB, videoId);
  if (!doc || doc.status !== "ready" || !doc.thumbnailType) {
    return c.json({ error: "Thumbnail not found" }, 404);
  }

  if (doc.isPrivate) {
    // Owner-only. Unlike isOwnerRequest (Bearer-gated for the byte route),
    // the dashboard loads this via <img>, which carries the session cookie —
    // so resolve the session from whatever credentials the request has.
    const { getAuth } = await import("../lib/auth");
    let ownerOk = false;
    try {
      const session = await getAuth(c.env).api.getSession({ headers: c.req.raw.headers });
      ownerOk = session?.user.id === doc.uid;
    } catch { /* not the owner */ }
    if (!ownerOk) return c.json({ error: "This video is private" }, 403);
  } else {
    const gate = await shareGate(c, doc, c.req.query("token"));
    if (gate.state !== "open") return c.json({ error: "Thumbnail unavailable" }, 403);
  }

  // Gated or private thumbnails must not land in the shared edge cache.
  const isPublic = !doc.isPrivate && !doc.passwordHash && !doc.maxViews && !doc.expiresAt;
  const cache = caches.default;
  if (isPublic) {
    const cached = await cache.match(c.req.raw);
    if (cached) return cached;
  }

  const object = await c.env.R2.get(thumbnailR2Key(videoId));
  if (!object) return c.json({ error: "Thumbnail not found" }, 404);

  const headers = new Headers();
  headers.set("Content-Type", object.httpMetadata?.contentType ?? doc.thumbnailType);
  headers.set("Content-Length", String(object.size));
  headers.set("Cache-Control", "public, max-age=300");
  const response = new Response(object.body, { status: 200, headers });

  // Only full 200s ever go in (never a 206 or a params-gated response) —
  // same rule as the media route's edge cache.
  if (isPublic && response.status === 200) {
    c.executionCtx.waitUntil(cache.put(c.req.raw, response.clone()));
  }
  return response;
});

// ---------------------------------------------------------------------------
// PATCH /video/:videoId/privacy — owner toggles visibility
// ---------------------------------------------------------------------------
videoRoutes.patch("/video/:videoId/privacy", requireAuth, requireEntitlement(), async (c) => {
  const videoId = c.req.param("videoId");
  const body: { isPrivate?: unknown } = await c.req
    .json<{ isPrivate?: unknown }>()
    .catch(() => ({}) as { isPrivate?: unknown });
  if (typeof body.isPrivate !== "boolean") {
    return c.json({ error: "isPrivate must be a boolean" }, 400);
  }

  const doc = await getSharedVideo(c.env.DB, videoId);
  if (!doc) return c.json({ error: "Video not found" }, 404);
  if (doc.uid !== c.get("user").uid) return c.json({ error: "Forbidden" }, 403);

  const changed = await setSharedVideoPrivacy(c.env.DB, videoId, body.isPrivate);
  if (!changed) return c.json({ error: "Video not found" }, 404);

  // MANDATORY, not an optimisation. GET /video/:id gates the privacy check on
  // a Cache-API copy held for s-maxage=300, so without this purge a video stays
  // publicly streamable for up to five minutes after being made private. That
  // is a privacy bug, not staleness.
  //
  // Known limit: Cache API deletes are per-colo, so another colo can still
  // serve its own cached copy until the TTL lapses. Do not advertise the toggle
  // as instant.
  await caches.default.delete(new Request(`https://meta.internal/video/${videoId}`));

  return c.json({ videoId, isPrivate: body.isPrivate });
});

// ---------------------------------------------------------------------------
// GET /videos — the signed-in user's library
// ---------------------------------------------------------------------------
/**
 * Returns storage numbers alongside the list so the dashboard stops hardcoding
 * a 10 GiB limit independently of `PRO_PLAN_LIMITS`.
 */
// Team library listing — any member of the org.
videoRoutes.get("/org/:orgId/videos", requireAuth, requireEntitlement(), async (c) => {
  const orgId = c.req.param("orgId");
  const uid = c.get("user").uid;
  const { isOrgMember, listOrgVideos } = await import("../lib/db");
  if (!(await isOrgMember(c.env.DB, orgId, uid))) {
    return c.json({ error: "Not a member of this team" }, 403);
  }
  const videos = await listOrgVideos(c.env.DB, orgId);
  return c.json({
    videos: videos.map((v) => ({
      videoId: v.videoId,
      fileName: v.fileName,
      durationSeconds: v.durationSeconds,
      createdAt: v.createdAt,
      isPrivate: v.isPrivate,
      url: v.url,
      uid: v.uid,
      orgId: v.orgId,
    })),
  });
});

// Share a video into (or remove it from) the org's team library.
// Uploader-only; requires teams on the uploader's plan and org membership.
videoRoutes.post("/video/:videoId/org", requireAuth, requireEntitlement(), async (c) => {
  const videoId = c.req.param("videoId");
  const uid = c.get("user").uid;
  const doc = await getSharedVideo(c.env.DB, videoId);
  if (!doc || doc.uid !== uid) return c.json({ error: "Video not found" }, 404);

  const body: { orgId?: unknown } = await c.req.json().catch(() => ({}));
  const orgId = typeof body.orgId === "string" && body.orgId.length > 0 ? body.orgId : null;

  const { isOrgMember, setVideoOrg } = await import("../lib/db");
  if (orgId) {
    const { featuresForTier } = await import("../lib/plans");
    const features = await featuresForTier(c.env.DB, c.get("entitlement").tier);
    if (!features.teams) {
      return c.json({ error: "Team libraries require a paid plan" }, 402);
    }
    if (!(await isOrgMember(c.env.DB, orgId, uid))) {
      return c.json({ error: "Not a member of this team" }, 403);
    }
  }
  await setVideoOrg(c.env.DB, videoId, orgId);
  // Org changes alter who may view — drop the per-colo metadata cache entry.
  await caches.default.delete(new Request(`https://meta.internal/video/${videoId}`));
  return c.json({ videoId, orgId });
});

videoRoutes.get("/videos", requireAuth, requireEntitlement(), async (c) => {
  const uid = c.get("user").uid;
  const [videos, used] = await Promise.all([
    listSharedVideos(c.env.DB, uid),
    storageUsageBytes(c.env.DB, uid),
  ]);
  return c.json({
    videos: videos.map((v) => ({
      videoId: v.videoId,
      orgId: v.orgId ?? null,
      fileName: v.fileName,
      contentType: v.contentType,
      fileSizeBytes: v.fileSizeBytes,
      durationSeconds: v.durationSeconds,
      isPrivate: v.isPrivate,
      createdAt: v.createdAt,
      // Rebuilt at read time, not the stored copy: the stored url is stamped
      // at upload with that moment's shareBaseURL, so rows written against an
      // old dev port (or a future domain change) would serve stale links
      // forever. The path shape is always /share/{id} — nothing rewrites it.
      url: `${shareBaseURL(c.env)}/share/${v.videoId}`,
      // For the "Open in CaptureCat" deep link (capturecat://open-project).
      projectId: v.projectId,
      // Share-page controls (migration 0012). The hash never leaves the
      // server — the dashboard only needs to know a password exists.
      allowDownload: v.allowDownload,
      hasPassword: v.passwordHash !== null,
      expiresAt: v.expiresAt,
      maxViews: v.maxViews,
      brandAccent: v.brandAccent,
      commentsEnabled: v.commentsEnabled,
      currentVersion: v.currentVersion,
      showVersionHistory: v.showVersionHistory,
      ctaLabel: v.ctaLabel,
      ctaUrl: v.ctaUrl,
      profileVisible: v.profileVisible,
      thumbnailType: v.thumbnailType,
      thumbnailUrl: v.thumbnailType
        ? `${new URL(c.env.BETTER_AUTH_URL).origin}/api/video/${v.videoId}/thumbnail`
        : null,
    })),
    storageUsedBytes: used,
    storageLimitBytes: PRO_PLAN_LIMITS.maxTotalStorageBytes,
  });
});
