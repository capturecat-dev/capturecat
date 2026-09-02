import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement, userRateLimit } from "../lib/entitlement";
import { checkAssertion } from "./attest";
import { getSharedVideo, deleteSharedVideo, listVideoVersions, deleteVideoVersion } from "../lib/db";

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
  const versions = await listVideoVersions(c.env.DB, videoId);
  const candidateKeys = Array.from(
    new Set(
      [
        doc.r2Key.length > 0 ? doc.r2Key : null,
        `videos/${videoId}.mp4`,
        ...versions.map((v) => v.r2Key),
      ].filter((value): value is string => value !== null)
    )
  );

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

  return c.json({ deleted: true, videoId });
});
