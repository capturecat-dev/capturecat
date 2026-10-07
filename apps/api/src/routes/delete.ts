import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement, userRateLimit } from "../lib/entitlement";
import { checkAssertion } from "./attest";
import { getSharedVideo, deleteSharedVideo, listVideoVersions, deleteVideoVersion } from "../lib/db";
import { deleteStoredObject } from "../lib/storage";

export const deleteRoutes = new Hono<{
  Bindings: Env;
  Variables: Variables;
}>();

/**
 * DELETE /video/:videoId
 * Owner-only: deletes R2 object + DB record.
 */
deleteRoutes.delete(
  "/video/:videoId",
  requireAuth,
  requireEntitlement(),
  userRateLimit({ limit: 30, windowSec: 60, scope: "delete" }),
  checkAssertion(),
  async (c) => {
  const user = c.get("user");
  const videoId = c.req.param("videoId");

  const doc = await getSharedVideo(c.env.DB, videoId);

  if (!doc) {
    return c.json({ error: "Video not found" }, 404);
  }

  if (doc.uid !== user.uid) {
    return c.json({ error: "Not authorized" }, 403);
  }

  // Every version's file goes too (migration 0017), plus the legacy key.
  // Files in the owner's own bucket (migration 0029) are listed separately:
  // they go through that bucket's S3 API, not the R2 binding.
  const versions = await listVideoVersions(c.env.DB, videoId);
  const customFiles = new Map<string, { storageId: string; key: string }>();
  for (const f of [{ storageId: doc.storageId, key: doc.r2Key }, ...versions.map((v) => ({ storageId: v.storageId, key: v.r2Key }))]) {
    if (f.storageId && f.key.length > 0) {
      customFiles.set(`${f.storageId}\n${f.key}`, { storageId: f.storageId, key: f.key });
    }
  }
  const candidateKeys = Array.from(
    new Set(
      [
        doc.r2Key.length > 0 && !doc.storageId ? doc.r2Key : null,
        `videos/${videoId}.mp4`,
        ...versions.filter((v) => !v.storageId).map((v) => v.r2Key),
        // The owner-uploaded poster (routes/video.ts thumbnailR2Key). It was
        // orphaned in R2 forever when the video went. Posters always live in
        // CaptureCat R2, whatever bucket the video is in.
        `thumbs/${videoId}`,
      ].filter((value): value is string => value !== null)
    )
  );

  // The owner's bucket may refuse (keys rotated, bucket deleted). The share
  // still goes — refusing would leave them a link they can never take down —
  // and the response names what is left for them to clean up.
  const leftInBucket: string[] = [];
  for (const f of customFiles.values()) {
    await deleteStoredObject(c.env, f.storageId, f.key).catch((err) => {
      console.error("delete: custom bucket refused", f.key, err);
      leftInBucket.push(f.key);
    });
  }

  for (const key of candidateKeys) {
    await c.env.R2.delete(key);
  }

  for (const key of candidateKeys) {
    const existingObject = await c.env.R2.get(key);
    if (existingObject) {
      return c.json(
        {
          error: "Failed to delete video from storage",
          videoId,
          r2Key: key,
        },
        500
      );
    }
  }

  // Delete DB records (version rows first — no FK, but never leave orphans)
  for (const v of versions) {
    await deleteVideoVersion(c.env.DB, videoId, v.versionNumber);
  }
  await c.env.DB
    .prepare("DELETE FROM playlist_videos WHERE video_id = ?")
    .bind(videoId)
    .run();
  await deleteSharedVideo(c.env.DB, videoId);

  const cache = caches.default;
  await cache.delete(new Request(`https://meta.internal/video/${videoId}`));

  return c.json({ deleted: true, videoId, ...(leftInBucket.length > 0 ? { leftInBucket } : {}) });
});
