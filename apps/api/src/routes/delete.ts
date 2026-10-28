import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement, userRateLimit } from "../lib/entitlement";
import { checkAssertion } from "./attest";
import { getSharedVideo } from "../lib/db";
import { deleteVideoEverywhere } from "../lib/video-delete";

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

  const result = await deleteVideoEverywhere(c.env, doc);
  if (!result.ok) {
    return c.json(
      {
        error: "Failed to delete video from storage",
        videoId,
        r2Key: result.r2Key,
      },
      500
    );
  }
  const { leftInBucket } = result;

  return c.json({ deleted: true, videoId, ...(leftInBucket.length > 0 ? { leftInBucket } : {}) });
});
