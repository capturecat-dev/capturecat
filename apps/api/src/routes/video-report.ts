/**
 * POST /video/:videoId/report  { reason, details? } → 201 { reported: true }
 *
 * A viewer reports a share from its page ("Report" under the player). Open to
 * anyone who can see the video — no account needed — and bounded:
 *   • the video must be one a viewer could actually watch (ready, not
 *     private, not already removed);
 *   • one OPEN report per reporter per video (a repeat updates it instead of
 *     stacking duplicates in the queue);
 *   • 10 reports per reporter per hour, globally (fixedWindowAllow).
 * The reporter is stored only as an HMAC of their IP (+ user id when signed
 * in) — lib/moderation.ts reporterHash. Reports land in the admin console's
 * Videos → Reported queue (routes/admin-moderation.ts).
 */
import { Hono } from "hono";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { getSharedVideo } from "../lib/db";
import { fixedWindowAllow } from "../lib/entitlement";
import { generateId } from "../lib/id";
import { parseJsonBody } from "../lib/validate";
import { REPORT_DETAILS_MAX, REPORT_REASONS, isRemoved, removedResponse, reporterHash } from "../lib/moderation";

export const videoReportRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

export const REPORT_RATE_LIMIT = 10;
const REPORT_RATE_WINDOW_SEC = 3600;

const reportBody = z.object({
  reason: z.enum(REPORT_REASONS),
  details: z.string().trim().max(REPORT_DETAILS_MAX).optional().nullable(),
});

/** The signed-in viewer's id, when there is a session; never required. */
async function optionalUid(c: { env: Env; req: { raw: Request } }): Promise<string | null> {
  if (!c.req.raw.headers.get("Cookie") && !c.req.raw.headers.get("Authorization")) return null;
  try {
    const { getAuth } = await import("../lib/auth");
    const session = await getAuth(c.env).api.getSession({ headers: c.req.raw.headers });
    return session?.user.id ?? null;
  } catch {
    return null;
  }
}

videoReportRoutes.post("/video/:videoId/report", async (c) => {
  const doc = await getSharedVideo(c.env.DB, c.req.param("videoId"));
  if (!doc || doc.status !== "ready" || doc.isPrivate) {
    return c.json({ error: "Video not found" }, 404);
  }
  if (isRemoved(doc)) return removedResponse(c);

  const parsed = await parseJsonBody(c.req, reportBody);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const { reason } = parsed.data;
  const details = parsed.data.details ? parsed.data.details : null;

  const uid = await optionalUid(c);
  const ip = c.req.header("CF-Connecting-IP") ?? "unknown";
  const reporter = await reporterHash(c.env.BETTER_AUTH_SECRET, ip, uid);

  if (!(await fixedWindowAllow(c.env.DB, `report:${reporter}`, REPORT_RATE_LIMIT, REPORT_RATE_WINDOW_SEC))) {
    return c.json({ error: "Too many reports — try again later" }, 429);
  }

  const now = new Date().toISOString();
  const open = await c.env.DB
    .prepare(`SELECT id FROM video_reports WHERE video_id = ? AND reporter_hash = ? AND resolved_at IS NULL LIMIT 1`)
    .bind(doc.videoId, reporter)
    .first<{ id: string }>();
  if (open) {
    await c.env.DB
      .prepare(`UPDATE video_reports SET reason = ?, details = ?, created_at = ? WHERE id = ?`)
      .bind(reason, details, now, open.id)
      .run();
  } else {
    await c.env.DB
      .prepare(
        `INSERT INTO video_reports (id, video_id, reason, details, reporter_hash, reporter_uid, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(generateId(), doc.videoId, reason, details, reporter, uid, now)
      .run();
  }
  return c.json({ reported: true }, 201);
});
