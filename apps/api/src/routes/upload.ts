import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement, userRateLimit } from "../lib/entitlement";
import { checkAssertion } from "./attest";
import { shareBaseURL } from "../lib/origins";
import { generateId } from "../lib/id";
import { createPresignedUploadUrl, headR2Object } from "../lib/presign";
import {
  getSharedVideo,
  upsertSharedVideo,
  deleteSharedVideo,
  storageUsageBytes,
  setAISummary,
  upsertTranscript,
  insertVideoVersion,
  getVideoVersion,
  nextVersionNumber,
  markVersionReady,
  setCurrentVersion,
  deleteVideoVersion,
  type TranscriptSegment,
} from "../lib/db";

export const uploadRoutes = new Hono<{
  Bindings: Env;
  Variables: Variables;
}>();

/**
 * POST /upload/video
 * Returns a presigned upload URL + videoId.
 * Client uploads directly to R2 using the presigned URL.
 */
/** Max file size: 1 GB (safety net) */
const MAX_FILE_SIZE = 1024 * 1024 * 1024;
/** Max total shared cloud storage per user: 10 GB */
const MAX_TOTAL_STORAGE_BYTES = 10 * 1024 * 1024 * 1024;
/** Max duration: 30 minutes */
const MAX_DURATION_SECONDS = 30 * 60;
/** Max uploads per user per day */
const MAX_UPLOADS_PER_DAY = 10;
/** Only allow video content types */
const ALLOWED_CONTENT_TYPES = ["video/mp4", "video/quicktime", "video/webm"];

/** Annotation markers for the share page: validated and re-serialized —
 *  never store client JSON verbatim. */
function validateAnnotations(annotations: unknown[]): string | null {
  const markers = annotations
    .slice(0, 100)
    .flatMap((raw): { start: number; end: number; label?: string; autoPause?: boolean; pauseDuration?: number }[] => {
      if (typeof raw !== "object" || raw === null) return [];
      const m = raw as Record<string, unknown>;
      const start = typeof m.start === "number" && isFinite(m.start) ? Math.max(0, m.start) : null;
      const end = typeof m.end === "number" && isFinite(m.end) ? Math.max(0, m.end) : null;
      if (start === null || end === null || end < start) return [];
      const marker: { start: number; end: number; label?: string; autoPause?: boolean; pauseDuration?: number } = {
        start: Math.round(start * 1000) / 1000,
        end: Math.round(end * 1000) / 1000,
      };
      if (typeof m.label === "string" && m.label.trim()) {
        marker.label = m.label.trim().slice(0, 120);
      }
      if (m.autoPause === true) {
        marker.autoPause = true;
        const d = typeof m.pauseDuration === "number" && isFinite(m.pauseDuration) ? m.pauseDuration : 2;
        marker.pauseDuration = Math.min(30, Math.max(0.5, d));
      }
      return [marker];
    });
  return markers.length > 0 ? JSON.stringify(markers) : null;
}

/** On-device subtitle segments, validated segment by segment. */
function validateTranscript(transcript: unknown[]): TranscriptSegment[] {
  return (transcript as Array<Record<string, unknown>>)
    .flatMap((seg) => {
      const start = typeof seg.start === "number" && isFinite(seg.start) ? seg.start : null;
      const end = typeof seg.end === "number" && isFinite(seg.end) ? seg.end : null;
      const text = typeof seg.text === "string" ? seg.text.trim().slice(0, 500) : "";
      if (start === null || end === null || end < start || !text) return [];
      const out: TranscriptSegment = {
        start: Math.round(start * 100) / 100,
        end: Math.round(end * 100) / 100,
        text,
      };
      if (Array.isArray(seg.words)) {
        const words = (seg.words as Array<Record<string, unknown>>)
          .flatMap((w) => {
            const ws = typeof w.start === "number" && isFinite(w.start) ? w.start : null;
            const we = typeof w.end === "number" && isFinite(w.end) ? w.end : null;
            const wt = typeof w.text === "string" ? w.text.trim().slice(0, 80) : "";
            // `<=` not `<`: zero-duration words make karaoke progress
            // (t - start) / (end - start) divide by zero downstream.
            if (ws === null || we === null || we <= ws || !wt) return [];
            return [{ start: Math.round(ws * 100) / 100, end: Math.round(we * 100) / 100, text: wt }];
          })
          .slice(0, 60);
        if (words.length > 0) out.words = words;
      }
      return [out];
    })
    .slice(0, 5000);
}

/** Local-model chapter list, same shape the Gemini path writes. */
function validateChapters(chapters: unknown): Array<{ start: number; label: string }> {
  if (!Array.isArray(chapters)) return [];
  return (chapters as Array<Record<string, unknown>>)
    .flatMap((ch) =>
      typeof ch.start === "number" && typeof ch.label === "string"
        ? [{ start: Math.max(0, ch.start), label: ch.label.slice(0, 60) }]
        : []
    )
    .slice(0, 12);
}
uploadRoutes.post(
  "/upload/video",
  requireAuth,
  // Server-resolved entitlement (blocked users bounced; tier attached for
  // future per-tier caps) + per-uid limit + App Attest (report-mode for now).
  requireEntitlement(),
  userRateLimit({ limit: 30, windowSec: 60, scope: "upload" }),
  checkAssertion(),
  async (c) => {
  const user = c.get("user");

  // Verify request comes from our app, not Postman/curl
  const appToken = c.req.header("X-App-Token");
  if (appToken !== c.env.APP_TOKEN) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const body = await c.req.json<{
    fileName: string;
    contentType?: string;
    fileSizeBytes?: number;
    durationSeconds?: number;
    commentsEnabled?: boolean;
    annotations?: unknown;
    projectId?: unknown;
    /** On-device subtitle segments {start, end, text} in output seconds. */
    transcript?: unknown;
    /** Local-model results generated on the Mac at share time. */
    aiTitle?: unknown;
    aiSummary?: unknown;
    aiChapters?: unknown;
  }>();

  // The editor project this export came from, so the dashboard can deep-link
  // back into the app. Strictly a UUID or dropped — never stored verbatim.
  const projectId =
    typeof body.projectId === "string" &&
    /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(
      body.projectId
    )
      ? body.projectId.toUpperCase()
      : null;

  if (!body.fileName) {
    return c.json({ error: "fileName is required" }, 400);
  }

  const annotationsJson = Array.isArray(body.annotations)
    ? validateAnnotations(body.annotations)
    : null;

  // Validate content type
  const contentType = body.contentType || "video/mp4";
  if (!ALLOWED_CONTENT_TYPES.includes(contentType)) {
    return c.json({ error: "Invalid content type" }, 400);
  }

  // Reject oversized files before they even upload
  if (body.fileSizeBytes && body.fileSizeBytes > MAX_FILE_SIZE) {
    return c.json({ error: "File too large (max 1 GB)" }, 413);
  }

  // Reject recordings longer than 30 minutes
  if (body.durationSeconds && body.durationSeconds > MAX_DURATION_SECONDS) {
    return c.json({ error: "Recording too long (max 30 minutes)" }, 413);
  }

  const currentUsageBytes = await storageUsageBytes(c.env.DB, user.uid);
  const requestedFileSize = body.fileSizeBytes ?? 0;

  if (requestedFileSize > 0 && currentUsageBytes + requestedFileSize > MAX_TOTAL_STORAGE_BYTES) {
    return c.json(
      {
        error: "Storage limit reached (10 GB). Delete shared videos before uploading more.",
        usedBytes: currentUsageBytes,
        limitBytes: MAX_TOTAL_STORAGE_BYTES,
        remainingBytes: Math.max(0, MAX_TOTAL_STORAGE_BYTES - currentUsageBytes),
      },
      413
    );
  }

  // Per-user daily upload limit (cached counter)
  const cache = caches.default;
  const today = new Date().toISOString().slice(0, 10);
  const userLimitKey = new Request(
    `https://rate-limit.internal/user-upload/${user.uid}/${today}`
  );
  const cachedCount = await cache.match(userLimitKey);
  let uploadCount = cachedCount ? parseInt(await cachedCount.text(), 10) : 0;

  if (uploadCount >= MAX_UPLOADS_PER_DAY) {
    return c.json({ error: "Daily upload limit reached (10 per day)" }, 429);
  }

  // Increment user counter (expires at end of day, ~24h TTL)
  uploadCount++;
  await cache.put(
    userLimitKey,
    new Response(String(uploadCount), {
      headers: { "Cache-Control": "s-maxage=86400" },
    })
  );

  const videoId = generateId();
  const r2Key = `videos/${videoId}.mp4`;

  // Create presigned upload URL with size limit
  const uploadUrl = await createPresignedUploadUrl({
    r2Endpoint: c.env.R2_ENDPOINT,
    accessKeyId: c.env.R2_ACCESS_KEY_ID,
    secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
    bucket: "capturecat",
    key: r2Key,
    contentType,
  });

  // Write pending record to D1
  await upsertSharedVideo(c.env.DB, {
    videoId,
    uid: user.uid,
    fileName: body.fileName,
    contentType,
    fileSizeBytes: 0,
    durationSeconds: body.durationSeconds ?? 0,
    r2Key,
    url: `${shareBaseURL(c.env)}/share/${videoId}`,
    isPrivate: false,
    status: "pending",
    createdAt: new Date().toISOString(),
    commentsEnabled: body.commentsEnabled === true,
    allowDownload: false,
    passwordHash: null,
    expiresAt: null,
    maxViews: null,
    brandAccent: null,
    annotationsJson,
    projectId,
    currentVersion: 1,
    showVersionHistory: false,
    ctaLabel: null,
    ctaUrl: null,
    profileVisible: true,
    thumbnailType: null,
  });

  // Version 1 of the new video (migration 0017) — replace uploads append to
  // this table and storage accounting sums it.
  await insertVideoVersion(c.env.DB, {
    versionId: `v1-${videoId}`,
    videoId,
    versionNumber: 1,
    r2Key,
    fileSizeBytes: 0,
    durationSeconds: body.durationSeconds ?? 0,
    status: "pending",
    createdAt: new Date().toISOString(),
  });

  // Transcript: the app's on-device subtitles, already retimed to output
  // seconds. Validated segment by segment — never stored verbatim.
  if (Array.isArray(body.transcript)) {
    const segments = validateTranscript(body.transcript);
    if (segments.length > 0) {
      await upsertTranscript(c.env.DB, videoId, user.uid, segments);
    }
  }

  // Local-model title/summary/chapters generated on the Mac at share time.
  // Same shape the server-side Gemini path writes; `ai_source` records which.
  const localTitle = typeof body.aiTitle === "string" ? body.aiTitle.slice(0, 80) : null;
  const localSummary = typeof body.aiSummary === "string" ? body.aiSummary.slice(0, 600) : null;
  const localChapters = validateChapters(body.aiChapters);
  if (localTitle || localSummary || localChapters.length > 0) {
    await setAISummary(c.env.DB, videoId, {
      title: localTitle,
      summary: localSummary,
      chaptersJson: localChapters.length > 0 ? JSON.stringify(localChapters) : null,
      source: "local",
    });
  }

  return c.json({ videoId, uploadUrl, r2Key });
  }
);

/**
 * POST /upload/video/:videoId/complete
 * Verifies the R2 object exists, updates the D1 record to "ready".
 */
uploadRoutes.post(
  "/upload/video/:videoId/complete",
  requireAuth,
  requireEntitlement(),
  userRateLimit({ limit: 30, windowSec: 60, scope: "upload" }),
  checkAssertion(),
  async (c) => {
    const appToken = c.req.header("X-App-Token");
    if (appToken !== c.env.APP_TOKEN) {
      return c.json({ error: "Forbidden" }, 403);
    }

    const user = c.get("user");
    const videoId = c.req.param("videoId");

    // Verify the record exists and belongs to this user
    const doc = await getSharedVideo(c.env.DB, videoId);

    if (!doc) {
      return c.json({ error: "Video not found" }, 404);
    }

    if (doc.uid !== user.uid) {
      return c.json({ error: "Not authorized" }, 403);
    }

    // Verify the R2 object actually exists (via S3 API, not local binding)
    const r2Key = doc.r2Key;
    const fileSize = await headR2Object({
      r2Endpoint: c.env.R2_ENDPOINT,
      accessKeyId: c.env.R2_ACCESS_KEY_ID,
      secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
      bucket: "capturecat",
      key: r2Key,
    });

    if (fileSize === null) {
      return c.json({ error: "Upload not found in storage" }, 404);
    }

    // Reject oversized uploads — delete the R2 object
    if (fileSize > MAX_FILE_SIZE) {
      await c.env.R2.delete(r2Key);
      await deleteSharedVideo(c.env.DB, videoId);
      return c.json({ error: "File too large (max 1 GB)" }, 413);
    }

    const currentUsageBytes = await storageUsageBytes(c.env.DB, user.uid);
    if (currentUsageBytes + fileSize > MAX_TOTAL_STORAGE_BYTES) {
      await c.env.R2.delete(r2Key);
      await deleteSharedVideo(c.env.DB, videoId);
      return c.json(
        {
          error: "Storage limit reached (10 GB). Delete shared videos before uploading more.",
          usedBytes: currentUsageBytes,
          limitBytes: MAX_TOTAL_STORAGE_BYTES,
          remainingBytes: Math.max(0, MAX_TOTAL_STORAGE_BYTES - currentUsageBytes),
        },
        413
      );
    }

    // Mark the record ready with the verified size
    await upsertSharedVideo(c.env.DB, {
      ...doc,
      status: "ready",
      fileSizeBytes: fileSize,
    });
    await markVersionReady(c.env.DB, videoId, doc.currentVersion, fileSize);

    return c.json({
      videoId,
      url: `${shareBaseURL(c.env)}/share/${videoId}`,
      status: "ready",
    });
  }
);

/**
 * POST /upload/video/:videoId/replace
 * Presigns an upload for a NEW version of an already-shared video. The share
 * link stays the same; the old file becomes history (migration 0017).
 */
uploadRoutes.post(
  "/upload/video/:videoId/replace",
  requireAuth,
  requireEntitlement(),
  userRateLimit({ limit: 30, windowSec: 60, scope: "upload" }),
  checkAssertion(),
  async (c) => {
    const user = c.get("user");

    const appToken = c.req.header("X-App-Token");
    if (appToken !== c.env.APP_TOKEN) {
      return c.json({ error: "Forbidden" }, 403);
    }

    const videoId = c.req.param("videoId");
    const doc = await getSharedVideo(c.env.DB, videoId);
    if (!doc || doc.status !== "ready") {
      return c.json({ error: "Video not found" }, 404);
    }
    if (doc.uid !== user.uid) {
      return c.json({ error: "Not authorized" }, 403);
    }

    const body = await c.req.json<{
      fileName?: string;
      contentType?: string;
      fileSizeBytes?: number;
      durationSeconds?: number;
      annotations?: unknown;
      transcript?: unknown;
      aiTitle?: unknown;
      aiSummary?: unknown;
      aiChapters?: unknown;
    }>().catch(() => ({} as Record<string, never>));

    const contentType = body.contentType || "video/mp4";
    if (!ALLOWED_CONTENT_TYPES.includes(contentType)) {
      return c.json({ error: "Invalid content type" }, 400);
    }
    if (body.fileSizeBytes && body.fileSizeBytes > MAX_FILE_SIZE) {
      return c.json({ error: "File too large (max 1 GB)" }, 413);
    }
    if (body.durationSeconds && body.durationSeconds > MAX_DURATION_SECONDS) {
      return c.json({ error: "Recording too long (max 30 minutes)" }, 413);
    }

    const currentUsageBytes = await storageUsageBytes(c.env.DB, user.uid);
    const requestedFileSize = body.fileSizeBytes ?? 0;
    if (requestedFileSize > 0 && currentUsageBytes + requestedFileSize > MAX_TOTAL_STORAGE_BYTES) {
      return c.json(
        {
          error: "Storage limit reached (10 GB). Delete shared videos or old versions before uploading more.",
          usedBytes: currentUsageBytes,
          limitBytes: MAX_TOTAL_STORAGE_BYTES,
          remainingBytes: Math.max(0, MAX_TOTAL_STORAGE_BYTES - currentUsageBytes),
        },
        413
      );
    }

    const versionNumber = await nextVersionNumber(c.env.DB, videoId);
    const r2Key = `videos/${videoId}/v${versionNumber}.mp4`;

    const uploadUrl = await createPresignedUploadUrl({
      r2Endpoint: c.env.R2_ENDPOINT,
      accessKeyId: c.env.R2_ACCESS_KEY_ID,
      secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
      bucket: "capturecat",
      key: r2Key,
      contentType,
    });

    await insertVideoVersion(c.env.DB, {
      versionId: generateId(),
      videoId,
      versionNumber,
      r2Key,
      fileSizeBytes: 0,
      durationSeconds: body.durationSeconds ?? doc.durationSeconds,
      status: "pending",
      createdAt: new Date().toISOString(),
    });

    return c.json({ videoId, version: versionNumber, uploadUrl, r2Key });
  }
);

/**
 * POST /upload/video/:videoId/replace/:version/complete
 * Verifies the new object, marks the version ready, and flips the share link
 * to it. Annotations/transcript/AI fields describe the NEW cut, so they only
 * land here — never at presign time, when the old cut is still live.
 */
uploadRoutes.post(
  "/upload/video/:videoId/replace/:version/complete",
  requireAuth,
  requireEntitlement(),
  userRateLimit({ limit: 30, windowSec: 60, scope: "upload" }),
  checkAssertion(),
  async (c) => {
    const appToken = c.req.header("X-App-Token");
    if (appToken !== c.env.APP_TOKEN) {
      return c.json({ error: "Forbidden" }, 403);
    }

    const user = c.get("user");
    const videoId = c.req.param("videoId");
    const versionNumber = parseInt(c.req.param("version"), 10);
    if (!Number.isInteger(versionNumber) || versionNumber < 2) {
      return c.json({ error: "Invalid version" }, 400);
    }

    const doc = await getSharedVideo(c.env.DB, videoId);
    if (!doc) return c.json({ error: "Video not found" }, 404);
    if (doc.uid !== user.uid) return c.json({ error: "Not authorized" }, 403);

    const version = await getVideoVersion(c.env.DB, videoId, versionNumber);
    if (!version || version.status !== "pending") {
      return c.json({ error: "Version not found" }, 404);
    }

    const fileSize = await headR2Object({
      r2Endpoint: c.env.R2_ENDPOINT,
      accessKeyId: c.env.R2_ACCESS_KEY_ID,
      secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
      bucket: "capturecat",
      key: version.r2Key,
    });
    if (fileSize === null) {
      return c.json({ error: "Upload not found in storage" }, 404);
    }

    if (fileSize > MAX_FILE_SIZE) {
      await c.env.R2.delete(version.r2Key);
      await deleteVideoVersion(c.env.DB, videoId, versionNumber);
      return c.json({ error: "File too large (max 1 GB)" }, 413);
    }

    const currentUsageBytes = await storageUsageBytes(c.env.DB, user.uid);
    if (currentUsageBytes + fileSize > MAX_TOTAL_STORAGE_BYTES) {
      await c.env.R2.delete(version.r2Key);
      await deleteVideoVersion(c.env.DB, videoId, versionNumber);
      return c.json(
        {
          error: "Storage limit reached (10 GB). Delete shared videos or old versions before uploading more.",
          usedBytes: currentUsageBytes,
          limitBytes: MAX_TOTAL_STORAGE_BYTES,
          remainingBytes: Math.max(0, MAX_TOTAL_STORAGE_BYTES - currentUsageBytes),
        },
        413
      );
    }

    await markVersionReady(c.env.DB, videoId, versionNumber, fileSize);
    await setCurrentVersion(c.env.DB, videoId, {
      ...version,
      status: "ready",
      fileSizeBytes: fileSize,
    });

    // The new cut's markers/transcript/AI metadata, validated the same way
    // the original upload validates them.
    const body = await c.req.json<{
      annotations?: unknown;
      transcript?: unknown;
      aiTitle?: unknown;
      aiSummary?: unknown;
      aiChapters?: unknown;
    }>().catch(() => ({} as Record<string, never>));

    if (Array.isArray(body.annotations)) {
      const annotationsJson = validateAnnotations(body.annotations);
      await c.env.DB
        .prepare("UPDATE shared_videos SET annotations_json = ? WHERE video_id = ?")
        .bind(annotationsJson, videoId)
        .run();
    }
    if (Array.isArray(body.transcript)) {
      const segments = validateTranscript(body.transcript);
      if (segments.length > 0) {
        await upsertTranscript(c.env.DB, videoId, user.uid, segments);
      }
    }
    const localTitle = typeof body.aiTitle === "string" ? body.aiTitle.slice(0, 80) : null;
    const localSummary = typeof body.aiSummary === "string" ? body.aiSummary.slice(0, 600) : null;
    const localChapters = validateChapters(body.aiChapters);
    if (localTitle || localSummary || localChapters.length > 0) {
      await setAISummary(c.env.DB, videoId, {
        title: localTitle,
        summary: localSummary,
        chaptersJson: localChapters.length > 0 ? JSON.stringify(localChapters) : null,
        source: "local",
      });
    }

    // The byte route gates on a 5-minute metadata cache — purge it so the
    // link plays the new version now, not in five minutes.
    await caches.default.delete(new Request(`https://meta.internal/video/${videoId}`));

    return c.json({
      videoId,
      version: versionNumber,
      url: doc.url || `${shareBaseURL(c.env)}/share/${videoId}`,
      status: "ready",
    });
  }
);
