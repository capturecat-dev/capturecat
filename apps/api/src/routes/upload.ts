import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement, userRateLimit } from "../lib/entitlement";
import { checkAssertion } from "./attest";
import { shareBaseURL } from "../lib/origins";
import { generateId } from "../lib/id";
import { createPresignedUploadUrl, headR2ObjectMeta } from "../lib/presign";
import { planForEntitlement } from "../lib/plans";
import { checkUploadAllowance, storageDeniedBody } from "../lib/upload-policy";
import { parseJsonBody } from "../lib/validate";
import {
  UploadVideoBodySchema,
  ReplaceVideoBodySchema,
  ReplaceCompleteBodySchema,
} from "../lib/upload-schemas";
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
  markVersionReadyWithinQuota,
  pendingUploadCount,
  setCurrentVersion,
  deleteVideoVersion,
} from "../lib/db";

export const uploadRoutes = new Hono<{
  Bindings: Env;
  Variables: Variables;
}>();

/**
 * Every cap here comes from the caller's plan row (`lib/plans.ts`) and is
 * decided by `checkUploadAllowance` (`lib/upload-policy.ts`). There are no
 * upload constants in this file on purpose: editing a plan in the admin
 * console is the whole job of changing what a tier may upload.
 *
 * Bodies are validated with the zod schemas in `lib/upload-schemas.ts`.
 */

/** Outstanding presigns per user, first uploads and replace versions together. */
const MAX_PENDING_PRESIGNS = 5;

/** Shares started today, from the per-colo cache counter. Cheap and
 *  approximate — the plan's `maxUploadsPerDay` is a courtesy cap, not a
 *  billing boundary; storage is the hard one. */
async function dailyUploadCounter(uid: string) {
  const cache = caches.default;
  const today = new Date().toISOString().slice(0, 10);
  const key = new Request(`https://rate-limit.internal/user-upload/${uid}/${today}`);
  const cached = await cache.match(key);
  const count = cached ? parseInt(await cached.text(), 10) || 0 : 0;
  return {
    count,
    // Expires at end of day, ~24h TTL.
    increment: () =>
      cache.put(
        key,
        new Response(String(count + 1), { headers: { "Cache-Control": "s-maxage=86400" } }),
      ),
  };
}

/**
 * POST /upload/video
 * Returns a presigned upload URL + videoId.
 * Client uploads directly to R2 using the presigned URL.
 */
uploadRoutes.post(
  "/upload/video",
  requireAuth,
  // Server-resolved entitlement (blocked users bounced; plan attached for the
  // per-plan caps below) + per-uid limit + App Attest (report-mode for now).
  requireEntitlement(),
  userRateLimit({ limit: 30, windowSec: 60, scope: "upload" }),
  checkAssertion(),
  async (c) => {
    const user = c.get("user");

    // X-App-Token is a client-version marker only. The app's value ships in
    // the open-source repo, so it authenticates nothing — genuineness is App
    // Attest's job (checkAssertion above), and identity is the bearer token.

    const parsed = await parseJsonBody(c.req, UploadVideoBodySchema);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const body = parsed.data;

    const plan = await planForEntitlement(c.env.DB, c.get("entitlement"));
    const [currentUsageBytes, daily] = await Promise.all([
      storageUsageBytes(c.env.DB, user.uid),
      dailyUploadCounter(user.uid),
    ]);

    const verdict = checkUploadAllowance(plan, {
      fileSizeBytes: body.fileSizeBytes,
      durationSeconds: body.durationSeconds,
      usedBytes: currentUsageBytes,
      uploadsToday: daily.count,
    });
    if (!verdict.ok) return c.json(verdict.body, verdict.status);

    // A presign is a liability until /complete: the object may already be in
    // R2 while the row still says pending, invisible to the storage quota.
    // Bound the number outstanding per user — first uploads AND replace
    // versions together (the hourly sweep clears strays). Checked BEFORE the
    // daily counter is spent, so a refused presign costs nothing.
    if ((await pendingUploadCount(c.env.DB, user.uid)) >= MAX_PENDING_PRESIGNS) {
      return c.json(
        { error: "Too many uploads in progress — finish or wait a moment before starting another." },
        429
      );
    }

    await daily.increment();

    const videoId = generateId();

    const r2Key = `videos/${videoId}.mp4`;

    // Create presigned upload URL with size limit. The declared size is
    // signed into the presigned PUT (see presign.ts).
    const uploadUrl = await createPresignedUploadUrl({
      r2Endpoint: c.env.R2_ENDPOINT,
      accessKeyId: c.env.R2_ACCESS_KEY_ID,
      secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
      bucket: "capturecat",
      key: r2Key,
      contentType: body.contentType,
      contentLength: body.fileSizeBytes,
    });

    // Write pending record to D1
    await upsertSharedVideo(c.env.DB, {
      videoId,
      uid: user.uid,
      fileName: body.fileName,
      contentType: body.contentType,
      fileSizeBytes: 0,
      durationSeconds: body.durationSeconds,
      r2Key,
      url: `${shareBaseURL(c.env)}/share/${videoId}`,
      isPrivate: false,
      status: "pending",
      createdAt: new Date().toISOString(),
      // The client asks; the plan decides. Comments are re-checked against
      // the owner's plan at read/write time too (routes/video.ts).
      commentsEnabled: body.commentsEnabled && plan.features.comments,
      allowDownload: false,
      passwordHash: null,
      expiresAt: null,
      maxViews: null,
      brandAccent: null,
      annotationsJson: body.annotations,
      projectId: body.projectId,
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
      durationSeconds: body.durationSeconds,
      status: "pending",
      createdAt: new Date().toISOString(),
    });

    // Transcript: the app's on-device subtitles, already retimed to output
    // seconds. Validated segment by segment — never stored verbatim.
    if (body.transcript && body.transcript.length > 0) {
      await upsertTranscript(c.env.DB, videoId, user.uid, body.transcript);
    }

    // Local-model title/summary/chapters generated on the Mac at share time.
    // Same shape the server-side Gemini path writes; `ai_source` records which.
    if (body.aiTitle || body.aiSummary || body.aiChapters.length > 0) {
      await setAISummary(c.env.DB, videoId, {
        title: body.aiTitle,
        summary: body.aiSummary,
        chaptersJson: body.aiChapters.length > 0 ? JSON.stringify(body.aiChapters) : null,
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
    // X-App-Token: client-version marker only — see /upload/video.

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

    // Idempotent: a retried /complete after a flaky response must not count
    // the same bytes twice, trip the cap, and delete a video that was fine.
    if (doc.status === "ready") {
      return c.json({
        videoId,
        url: `${shareBaseURL(c.env)}/share/${videoId}`,
        status: "ready",
      });
    }

    // Verify the R2 object actually exists (via S3 API, not local binding)
    const r2Key = doc.r2Key;
    const head = await headR2ObjectMeta({
      r2Endpoint: c.env.R2_ENDPOINT,
      accessKeyId: c.env.R2_ACCESS_KEY_ID,
      secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
      bucket: "capturecat",
      key: r2Key,
    });

    if (head === null) {
      return c.json({ error: "Upload not found in storage" }, 404);
    }
    const fileSize = head.size;

    // Re-check against the plan with the VERIFIED size: the client's declared
    // size was signed into the PUT, but the plan may have changed since the
    // presign, and the bytes are what storage accounting will sum.
    const plan = await planForEntitlement(c.env.DB, c.get("entitlement"));
    const currentUsageBytes = await storageUsageBytes(c.env.DB, user.uid);
    const verdict = checkUploadAllowance(plan, { fileSizeBytes: fileSize, usedBytes: currentUsageBytes });
    const accepted = verdict.ok
      ? // The storage cap is decided INSIDE this UPDATE (one statement, no
        // read-then-check window), so concurrent completes cannot all land.
        await markVersionReadyWithinQuota(c.env.DB, {
          uid: user.uid,
          videoId,
          versionNumber: doc.currentVersion,
          fileSizeBytes: fileSize,
          limitBytes: plan.limits.maxTotalStorageBytes,
        })
      : "over_quota";
    if (!verdict.ok || accepted !== "ready") {
      // Denied after the bytes landed: delete the object so it never counts.
      await c.env.R2.delete(r2Key);
      await deleteSharedVideo(c.env.DB, videoId);
      return c.json(
        verdict.ok ? storageDeniedBody(plan, currentUsageBytes) : verdict.body,
        verdict.ok ? 413 : verdict.status,
      );
    }

    // Mark the record ready with the verified size and pin the verified
    // bytes: the byte route refuses a later re-PUT on the still-live presign.
    await upsertSharedVideo(c.env.DB, {
      ...doc,
      status: "ready",
      fileSizeBytes: fileSize,
    });
    await c.env.DB.prepare("UPDATE shared_videos SET etag = ? WHERE video_id = ?")
      .bind(head.etag, videoId)
      .run();

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

    // X-App-Token: client-version marker only — see /upload/video.

    const videoId = c.req.param("videoId");
    const doc = await getSharedVideo(c.env.DB, videoId);
    if (!doc || doc.status !== "ready") {
      return c.json({ error: "Video not found" }, 404);
    }
    if (doc.uid !== user.uid) {
      return c.json({ error: "Not authorized" }, 403);
    }

    const parsed = await parseJsonBody(c.req, ReplaceVideoBodySchema, { emptyOnInvalidJson: true });
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const body = parsed.data;

    if ((await pendingUploadCount(c.env.DB, user.uid)) >= MAX_PENDING_PRESIGNS) {
      return c.json(
        { error: "Too many uploads in progress — finish or wait a moment before starting another." },
        429
      );
    }

    // Replacing a share is not a new share, so the daily cap does not apply;
    // storage, size and duration do.
    const plan = await planForEntitlement(c.env.DB, c.get("entitlement"));
    const currentUsageBytes = await storageUsageBytes(c.env.DB, user.uid);
    const verdict = checkUploadAllowance(plan, {
      fileSizeBytes: body.fileSizeBytes,
      durationSeconds: body.durationSeconds ?? 0,
      usedBytes: currentUsageBytes,
    });
    if (!verdict.ok) return c.json(verdict.body, verdict.status);

    const versionNumber = await nextVersionNumber(c.env.DB, videoId);
    const r2Key = `videos/${videoId}/v${versionNumber}.mp4`;

    const uploadUrl = await createPresignedUploadUrl({
      r2Endpoint: c.env.R2_ENDPOINT,
      accessKeyId: c.env.R2_ACCESS_KEY_ID,
      secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
      bucket: "capturecat",
      key: r2Key,
      contentType: body.contentType,
      // Same signed-size rule as the first upload (see presign.ts).
      contentLength: body.fileSizeBytes,
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
    // X-App-Token: client-version marker only — see /upload/video.

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

    // Validate the body before touching storage so a malformed request
    // cannot leave a half-flipped version behind.
    const parsed = await parseJsonBody(c.req, ReplaceCompleteBodySchema, { emptyOnInvalidJson: true });
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const body = parsed.data;

    const head = await headR2ObjectMeta({
      r2Endpoint: c.env.R2_ENDPOINT,
      accessKeyId: c.env.R2_ACCESS_KEY_ID,
      secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
      bucket: "capturecat",
      key: version.r2Key,
    });
    if (head === null) {
      return c.json({ error: "Upload not found in storage" }, 404);
    }
    const fileSize = head.size;

    // Same verified-size re-check and atomic accept as /complete.
    const plan = await planForEntitlement(c.env.DB, c.get("entitlement"));
    const currentUsageBytes = await storageUsageBytes(c.env.DB, user.uid);
    const verdict = checkUploadAllowance(plan, { fileSizeBytes: fileSize, usedBytes: currentUsageBytes });
    const accepted = verdict.ok
      ? await markVersionReadyWithinQuota(c.env.DB, {
          uid: user.uid,
          videoId,
          versionNumber,
          fileSizeBytes: fileSize,
          limitBytes: plan.limits.maxTotalStorageBytes,
        })
      : "over_quota";
    if (!verdict.ok || accepted !== "ready") {
      await c.env.R2.delete(version.r2Key);
      await deleteVideoVersion(c.env.DB, videoId, versionNumber);
      return c.json(
        verdict.ok ? storageDeniedBody(plan, currentUsageBytes) : verdict.body,
        verdict.ok ? 413 : verdict.status,
      );
    }

    // The share link now points at the new cut, pinned to ITS ETag. Leaving
    // the old ETag behind made the byte route 404 every replaced video.
    await setCurrentVersion(
      c.env.DB,
      videoId,
      { ...version, status: "ready", fileSizeBytes: fileSize },
      head.etag,
    );

    // The new cut's markers/transcript/AI metadata, validated the same way
    // the original upload validates them.
    if (body.annotations !== undefined) {
      await c.env.DB
        .prepare("UPDATE shared_videos SET annotations_json = ? WHERE video_id = ?")
        .bind(body.annotations, videoId)
        .run();
    }
    if (body.transcript && body.transcript.length > 0) {
      await upsertTranscript(c.env.DB, videoId, user.uid, body.transcript);
    }
    if (body.aiTitle || body.aiSummary || body.aiChapters.length > 0) {
      await setAISummary(c.env.DB, videoId, {
        title: body.aiTitle,
        summary: body.aiSummary,
        chaptersJson: body.aiChapters.length > 0 ? JSON.stringify(body.aiChapters) : null,
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
