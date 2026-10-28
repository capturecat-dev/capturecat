import { Hono } from "hono";
import type { Env, Variables } from "../types";
import {
  deleteVideoVersion,
  getSharedVideo,
  getVideoVersion,
  listSharedVideos,
  listVideoComments,
  listVideoVersions,
  setCurrentVersion,
  setSharedVideoPrivacy,
  setThumbnailType,
  storageUsageBytes,
  viewCount,
} from "../lib/db";
import type { VideoMetadata } from "../types";
import { getAISummary, getTranscript } from "../lib/db";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement, userRateLimit, fixedWindowAllow, planForUser } from "../lib/entitlement";
import { headR2ObjectMeta } from "../lib/presign";
import { customObjectUrl, deleteStoredObject, storeFor, StorageUnavailableError } from "../lib/storage";
import { resolveDomain, domainIsLive } from "../lib/db";
import { readValidatedImage } from "../lib/uploads";
import { planForEntitlement } from "../lib/plans";
import { shareBaseURL, webOrigins } from "../lib/origins";
import {
  MAX_COMMENT_REQUEST_BYTES,
  commentAuthorName,
  sessionAvatar,
  toPublicComment,
} from "../lib/comments";
import {
  COMMENT_RATE_LIMIT,
  COMMENT_RATE_WINDOW_SEC,
  MAX_COMMENTS_PER_VIDEO,
  commentsOpen,
  postComment,
} from "../lib/comment-post";
import {
  applyShareControls,
  canViewVideo,
  passwordDigest,
  shareControlsPatch,
  toHex,
  verifyPassword,
  type ShareControlsBody,
} from "../lib/video-share";
import { backgroundOf } from "../lib/webhooks";

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
    if (gate.state === "paused") return c.json({ error: "This share is paused" }, 403);
  }

  // Version pinning (migration 0017). `?v=N` streams a specific version —
  // any ready version when the owner exposed history, otherwise only the
  // current one (or anything, for the owner). No `?v` streams the current
  // version, whatever it is today.
  let r2Key = doc.r2Key;
  let storageId = doc.storageId ?? null;
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
      storageId = version.storageId ?? null;
    }
  }

  // The file is in the owner's own bucket (migration 0029): every gate above
  // has passed, so hand the player a short-lived URL to it. A redirect, not a
  // proxy — the bytes never pass through the Worker, and <video> follows it
  // and sends its Range requests straight to the bucket. Never cached: the
  // URL is a credential that outlives no gate for long. (No ETag pin here:
  // the pin guards CaptureCat's quota against a re-PUT, and these bytes are
  // not in it.)
  if (storageId) {
    try {
      const store = await storeFor(c.env, storageId);
      const location = await customObjectUrl(store, r2Key, {
        // Gated shares get a short window; a public share's player may sit
        // paused for a while before it seeks again.
        expiresIn: isPublicShare(doc) ? 6 * 3600 : 3600,
        contentType: doc.contentType || "video/mp4",
      });
      return new Response(null, {
        status: 302,
        headers: {
          Location: location,
          "Cache-Control": "private, no-store",
          "Referrer-Policy": "no-referrer",
        },
      });
    } catch (err) {
      if (err instanceof StorageUnavailableError) {
        return c.json({ error: "Video file not available from its storage bucket" }, 502);
      }
      throw err;
    }
  }

  const rangeHeader = c.req.header("Range");
  // Gated videos must not land in the shared edge cache — the cache key is
  // the URL and a cached copy would outlive the gate.
  const isPublic = isPublicShare(doc);

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

/** No privacy flag and no password/expiry/view-cap gate. */
function isPublicShare(doc: VideoMetadata): boolean {
  return !doc.isPrivate && !doc.passwordHash && !doc.maxViews && !doc.expiresAt;
}

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
    // The uploader, or a team-library member while the uploader's plan
    // includes teams (lib/video-share.ts — the MCP server's rule too).
    return await canViewVideo(c.env, doc, session.user.id);
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Share gates: password / expiry / view cap (migration 0012)
// ---------------------------------------------------------------------------

// Password hashing (passwordDigest / verifyPassword) lives in
// lib/video-share.ts, shared with the MCP update_share_settings tool.

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
  | { state: "view_limit" }
  /** The OWNER's plan no longer includes cloud sharing. Bytes stay in R2 so
   *  a resubscribe restores every link; until then nothing streams. */
  | { state: "paused" };

/** The share-page gate, shared by /meta, the byte route, and /download so the
 *  page and the stream can never disagree. */
async function shareGate(
  c: { env: Env },
  doc: VideoMetadata,
  token: string | undefined
): Promise<ShareGate> {
  // Sharing is a plan feature of the uploader, checked at VIEW time as well
  // as upload time. Without this, one month of Pro bought permanent hosting:
  // caps were only ever enforced on the upload path.
  const ownerPlan = await planForUser(c.env, doc.uid);
  if (!ownerPlan.features.cloudShare) {
    return { state: "paused" };
  }
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
  // The share page forwards the host it is rendering on. A customer's custom
  // domain serves ONLY that customer's videos, only while the domain is live
  // and their plan still includes custom domains — never someone else's
  // share, and never after a downgrade.
  const shareHost = (c.req.header("X-Share-Host") ?? "").toLowerCase().replace(/:\d+$/, "");
  if (shareHost && !isFirstPartyShareHost(shareHost)) {
    const record = await resolveDomain(c.env.DB, shareHost);
    if (!record || !domainIsLive(record) || record.uid !== doc.uid) {
      return c.json({ error: "Video not found" }, 404);
    }
    if (!(await planForUser(c.env, record.uid)).features.customDomain) {
      return c.json({ error: "Video not found" }, 404);
    }
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

  const safeName = doc.fileName.replace(/[^\w.\- ]/g, "_") || "video.mp4";

  // Owner's own bucket (0029): a signed URL that forces `attachment`.
  if (doc.storageId) {
    try {
      const store = await storeFor(c.env, doc.storageId);
      const location = await customObjectUrl(store, doc.r2Key, {
        expiresIn: 900,
        contentType: doc.contentType || "video/mp4",
        downloadFileName: safeName,
      });
      return new Response(null, {
        status: 302,
        headers: { Location: location, "Cache-Control": "private, no-store", "Referrer-Policy": "no-referrer" },
      });
    } catch (err) {
      if (err instanceof StorageUnavailableError) {
        return c.json({ error: "Video file not available from its storage bucket" }, 502);
      }
      throw err;
    }
  }

  const object = await c.env.R2.get(doc.r2Key);
  if (!object) return c.json({ error: "Video file not found in storage" }, 404);

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

  const body: ShareControlsBody = await c.req.json().catch(() => ({}));
  // Validation lives in lib/video-share.ts — the MCP update_share_settings
  // tool runs the same function, so neither can set what the other refuses.
  const patch = await shareControlsPatch(videoId, body);

  if (Object.keys(patch).length === 0) {
    return c.json({ error: "No valid fields" }, 400);
  }
  // Writes and then does the same mandatory purge as the privacy toggle —
  // the byte route's metadata cache would otherwise serve the OLD gates.
  const changed = await applyShareControls(c.env, videoId, patch);
  if (!changed) return c.json({ error: "Video not found" }, 404);

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

/** Same visibility gate as /meta and the byte route: ready, public, comments
 *  switched on, the uploader's plan still includes comments, AND the share
 *  gate is open (password → the unlock token rides as ?token=, expiry, view
 *  cap, paused). `commentsEnabled` is a client-sent flag; the plan flag is
 *  the entitlement. Before 0031 the comment routes skipped the share gate, so
 *  a password-protected video's comments were readable without the password. */
async function commentableVideo(
  c: { env: Env; req: { query(name: string): string | undefined } },
  videoId: string
) {
  const doc = await getSharedVideo(c.env.DB, videoId);
  // Ready, public, switched on, and the uploader's plan includes comments:
  // lib/comment-post.ts, shared with the MCP post_comment tool.
  if (!doc || !(await commentsOpen(c.env, doc))) return null;
  if ((await shareGate(c, doc, c.req.query("token"))).state !== "open") return null;
  return doc;
}

/**
 * Who is commenting, when they are signed in. Comments stay public-write —
 * this only ATTACHES an identity (name, session avatar, owner badge); a
 * request without one is simply anonymous.
 *
 * Cookie sessions are honoured on a write only from a trusted web origin
 * (the same list requireAuth's CSRF gate uses): otherwise any site could make
 * a signed-in owner "post" an owner-badged reply with a cross-site form.
 * Bearer callers are exempt for the same reason requireAuth exempts them.
 */
async function commenterSession(
  c: { env: Env; req: { method: string; header(name: string): string | undefined; raw: Request } }
): Promise<{ uid: string; name: string | null; image: string | null } | null> {
  const bearer = c.req.header("Authorization")?.startsWith("Bearer ") === true;
  if (!bearer && !c.req.header("Cookie")) return null;
  if (!bearer && c.req.method !== "GET" && c.req.method !== "HEAD") {
    const origin = c.req.header("Origin");
    if (!origin || !webOrigins(c.env).includes(origin)) return null;
  }
  const { getAuth } = await import("../lib/auth");
  try {
    const session = await getAuth(c.env).api.getSession({ headers: c.req.raw.headers });
    if (!session) return null;
    const user = session.user as { id: string; name?: string | null; image?: string | null; blocked?: boolean | null };
    if (user.blocked === true) return null;
    return { uid: user.id, name: user.name ?? null, image: user.image ?? null };
  } catch {
    return null;
  }
}

/** Hosts that serve share pages first-party. Anything else is a customer's
 *  custom domain and must resolve through custom_domains. */
function isFirstPartyShareHost(host: string): boolean {
  return (
    host === "capturecat.so" ||
    host.endsWith(".capturecat.so") ||
    host === "localhost" ||
    host.startsWith("127.0.0.1") ||
    host.endsWith(".workers.dev")
  );
}

/**
 * GET /video/:videoId/comments → { comments: PublicComment[], viewer }
 *
 * Flat list, top-level comments and replies together (replies carry
 * `parentId`); the page builds the threads. `viewer` describes the signed-in
 * caller (null when anonymous) so the composer can say who is posting.
 */
videoRoutes.get("/video/:videoId/comments", async (c) => {
  const doc = await commentableVideo(c, c.req.param("videoId"));
  if (!doc) return c.json({ error: "Comments unavailable" }, 404);
  const [comments, viewer] = await Promise.all([
    listVideoComments(c.env.DB, doc.videoId, MAX_COMMENTS_PER_VIDEO),
    commenterSession(c),
  ]);
  return c.json({
    comments: comments.map((cm) => toPublicComment(cm, doc.uid)),
    viewer: viewer
      ? {
          name: commentAuthorName(viewer.name, null),
          image: sessionAvatar(viewer.image),
          isOwner: viewer.uid === doc.uid,
        }
      : null,
  });
});

// MAX_COMMENTS_PER_VIDEO, MAX_REPLIES_PER_THREAD and COMMENT_RATE_LIMIT live
// in lib/comment-post.ts with the validation they bound.

/**
 * POST /video/:videoId/comments
 *   { body, authorName?, videoTime?, parentId?, annotation? } → { comment }
 *
 * `parentId` makes it a reply (one level deep, same video; it inherits the
 * parent's time and cannot carry a drawing). `annotation` is the v1 shape
 * list from lib/comments.ts, validated strictly and stored canonical.
 */
videoRoutes.post("/video/:videoId/comments", async (c) => {
  const doc = await commentableVideo(c, c.req.param("videoId"));
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
  if (!(await fixedWindowAllow(c.env.DB, `comment:${ip}`, COMMENT_RATE_LIMIT, COMMENT_RATE_WINDOW_SEC))) {
    return c.json({ error: "Slow down — try again in a few minutes" }, 429);
  }

  // Bounded BEFORE parsing: an annotation is the one large field, and its
  // validator caps the stored form, not what a client may send.
  const declared = Number(c.req.header("Content-Length") ?? "0");
  if (declared > MAX_COMMENT_REQUEST_BYTES) {
    return c.json({ error: "Comment is too large" }, 413);
  }
  const rawBody = await c.req.text().catch(() => "");
  if (rawBody.length > MAX_COMMENT_REQUEST_BYTES) {
    return c.json({ error: "Comment is too large" }, 413);
  }
  let body: {
    authorName?: unknown;
    body?: unknown;
    videoTime?: unknown;
    parentId?: unknown;
    annotation?: unknown;
  } = {};
  try {
    const parsed: unknown = JSON.parse(rawBody);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) body = parsed;
  } catch {
    body = {};
  }

  // Identity comes from the session only — never from the body.
  const session = await commenterSession(c);
  // Caps, body, drawing and threading rules: lib/comment-post.ts.
  const result = await postComment(
    c.env,
    doc,
    body,
    {
      authorName: commentAuthorName(session?.name, body.authorName),
      authorUid: session?.uid ?? null,
      authorImage: session ? sessionAvatar(session.image) : null,
    },
    { env: c.env, waitUntil: backgroundOf(c) },
  );
  if (!result.ok) return c.json({ error: result.error }, result.status);

  return c.json({ comment: result.comment });
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

    // Re-pin the ETag to the object actually being restored; the presign
    // that created it is long expired, but the byte route still compares.
    let store;
    try {
      store = await storeFor(c.env, version.storageId);
    } catch (err) {
      if (err instanceof StorageUnavailableError) {
        return c.json({ error: err.message, code: "storage_unavailable" }, 503);
      }
      throw err;
    }
    const head = await headR2ObjectMeta({
      ...store.connection,
      bucket: store.bucket,
      key: version.r2Key,
    });
    if (head === null) return c.json({ error: "Version file not found in storage" }, 404);
    await setCurrentVersion(c.env.DB, videoId, version, head.etag);
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
    const sameFile = (key: string, storageId: string | null | undefined) =>
      key === version.r2Key && (storageId ?? null) === (version.storageId ?? null);
    const keyStillUsed =
      sameFile(doc.r2Key, doc.storageId) || others.some((v) => sameFile(v.r2Key, v.storageId));
    let leftInBucket = false;
    if (!keyStillUsed) {
      if (version.storageId) {
        // The owner's own bucket may refuse (keys rotated, bucket gone). The
        // version still goes: the file is theirs to clean up, and keeping the
        // row would only list a version that no longer plays.
        await deleteStoredObject(c.env, version.storageId, version.r2Key).catch((err) => {
          console.error("versions: could not delete from custom bucket", err);
          leftInBucket = true;
        });
      } else {
        await c.env.R2.delete(version.r2Key);
      }
    }
    await deleteVideoVersion(c.env.DB, videoId, versionNumber);

    return c.json({ videoId, deletedVersion: versionNumber, ...(leftInBucket ? { leftInBucket: [version.r2Key] } : {}) });
  }
);

// ---------------------------------------------------------------------------
// Custom thumbnails (migration 0020) — owner-uploaded poster image in R2 at
// `thumbs/{videoId}`, existence recorded in shared_videos.thumbnail_type.
// ---------------------------------------------------------------------------

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

    // Shared image validation (lib/uploads): type allowlist + magic-byte
    // sniff + double size check — same rules as team logos.
    const img = await readValidatedImage(c.req, {
      maxBytes: THUMBNAIL_MAX_BYTES,
      label: "Thumbnail",
    });
    if (!img.ok) return c.json({ error: img.error }, img.status);
    const contentType = img.contentType;

    await c.env.R2.put(thumbnailR2Key(videoId), img.bytes, {
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
 * Returns storage numbers alongside the list so the dashboard shows the
 * caller's OWN plan limit, not a hardcoded one.
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
    const features = await featuresForTier(c.env.DB, c.get("entitlement").tier, c.get("entitlement").planName);
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
  const [videos, used, plan] = await Promise.all([
    listSharedVideos(c.env.DB, uid),
    storageUsageBytes(c.env.DB, uid),
    planForEntitlement(c.env.DB, c.get("entitlement")),
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
    storageLimitBytes: plan.limits.maxTotalStorageBytes,
  });
});
