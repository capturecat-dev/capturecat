/**
 * Viewer analytics for shared videos.
 *
 * The share page batches events and posts them here (sendBeacon on unload,
 * fetch otherwise). Ingest is public — the share page itself is public — but
 * write-shaped like comments: rate-limited per IP, size-capped per batch, and
 * hard-capped per video so a hostile viewer cannot grow a row set without
 * bound. Reads are owner-only.
 *
 * "Where they stopped" is derived, not stored: the player emits a 'tick' once
 * per watched second-bucket, and a session's drop-off point is its max tick.
 */

import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { getSharedVideo, listVideoComments } from "../lib/db";
import { requireAuth } from "../middleware/auth";
import { generateId } from "../lib/id";

export const analyticsRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

const EVENT_TYPES = new Set(["tick", "play", "pause", "seek", "ended", "click", "cta"]);
const MAX_EVENTS_PER_BATCH = 50;
/** Runaway backstop per video; aggregates stay meaningful long before this. */
const MAX_EVENTS_PER_VIDEO = 200_000;
/** Batches allowed per IP per minute. */
const INGEST_RATE_LIMIT = 30;

interface IncomingEvent {
  type?: unknown;
  videoTime?: unknown;
  meta?: unknown;
}

analyticsRoutes.post("/video/:videoId/analytics", async (c) => {
  const doc = await getSharedVideo(c.env.DB, c.req.param("videoId"));
  // Same visibility gate as the byte route: analytics only exist for videos a
  // viewer could actually watch.
  if (!doc || doc.status !== "ready" || doc.isPrivate) {
    return c.json({ error: "Video not found" }, 404);
  }

  // Per-IP window via the edge cache, mirroring the comment limiter.
  const ip = c.req.header("CF-Connecting-IP") ?? "unknown";
  const windowKey = Math.floor(Date.now() / 60_000);
  const rateKey = new Request(
    `https://rate-limit.internal/analytics/${encodeURIComponent(ip)}/${windowKey}`
  );
  const cache = caches.default;
  const cached = await cache.match(rateKey);
  const count = cached ? parseInt(await cached.text(), 10) : 0;
  if (count >= INGEST_RATE_LIMIT) return c.json({ ok: true }, 202);
  await cache.put(
    rateKey,
    new Response(String(count + 1), { headers: { "Cache-Control": "s-maxage=60" } })
  );

  const body: { sessionId?: unknown; events?: unknown; referrer?: unknown } =
    await c.req.json().catch(() => ({}));
  const sessionId =
    typeof body.sessionId === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(body.sessionId)
      ? body.sessionId
      : null;
  if (!sessionId) return c.json({ error: "sessionId required" }, 400);

  const now = new Date().toISOString();

  // First contact from a session registers the view. The unique index on
  // (video_id, session_id) makes this idempotent across batches.
  const referrer =
    typeof body.referrer === "string" ? body.referrer.slice(0, 200) : null;
  const cf = (c.req.raw as Request & { cf?: { country?: string } }).cf;
  const ua = c.req.header("User-Agent") ?? "";
  const device = /Mobi|Android|iPhone|iPad/i.test(ua) ? "mobile" : "desktop";
  await c.env.DB.prepare(
    `INSERT OR IGNORE INTO video_views
       (view_id, video_id, session_id, referrer, country, device, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(generateId(), doc.videoId, sessionId, referrer, cf?.country ?? null, device, now)
    .run();

  const rawEvents = Array.isArray(body.events)
    ? (body.events as IncomingEvent[]).slice(0, MAX_EVENTS_PER_BATCH)
    : [];
  const maxTime = Math.max(0, doc.durationSeconds);
  const events = rawEvents.flatMap((e) => {
    if (typeof e.type !== "string" || !EVENT_TYPES.has(e.type)) return [];
    const t =
      typeof e.videoTime === "number" && isFinite(e.videoTime)
        ? Math.min(Math.max(0, e.videoTime), maxTime)
        : 0;
    const meta =
      typeof e.meta === "string" ? e.meta.slice(0, 200) : null;
    return [{ type: e.type, videoTime: Math.round(t * 1000) / 1000, meta }];
  });

  if (events.length > 0) {
    const totalRow = await c.env.DB.prepare(
      "SELECT COUNT(*) AS n FROM video_events WHERE video_id = ?"
    )
      .bind(doc.videoId)
      .first<{ n: number }>();
    if ((totalRow?.n ?? 0) < MAX_EVENTS_PER_VIDEO) {
      const stmt = c.env.DB.prepare(
        `INSERT INTO video_events
           (event_id, video_id, session_id, type, video_time, meta, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      );
      await c.env.DB.batch(
        events.map((e) =>
          stmt.bind(generateId(), doc.videoId, sessionId, e.type, e.videoTime, e.meta, now)
        )
      );
    }
  }

  return c.json({ ok: true });
});

// ---------------------------------------------------------------------------
// GET /video/:videoId/analytics — owner-only aggregates
// ---------------------------------------------------------------------------
analyticsRoutes.get("/video/:videoId/analytics", requireAuth, async (c) => {
  const doc = await getSharedVideo(c.env.DB, c.req.param("videoId"));
  if (!doc) return c.json({ error: "Video not found" }, 404);
  if (doc.uid !== c.get("user").uid) return c.json({ error: "Forbidden" }, 403);

  const db = c.env.DB;
  const id = doc.videoId;

  const [views, heatmap, clicks, stops, countries, referrers, plays, completions, ctaClicks] =
    await Promise.all([
      db
        .prepare("SELECT COUNT(*) AS n FROM video_views WHERE video_id = ?")
        .bind(id)
        .first<{ n: number }>(),
      db
        .prepare(
          `SELECT CAST(video_time AS INTEGER) AS second,
                  COUNT(DISTINCT session_id) AS viewers
             FROM video_events
            WHERE video_id = ? AND type = 'tick'
            GROUP BY second ORDER BY second`
        )
        .bind(id)
        .all<{ second: number; viewers: number }>(),
      db
        .prepare(
          `SELECT CAST(video_time AS INTEGER) AS second,
                  COUNT(*) AS count
             FROM video_events
            WHERE video_id = ? AND type = 'click'
            GROUP BY second ORDER BY count DESC LIMIT 50`
        )
        .bind(id)
        .all<{ second: number; count: number }>(),
      // Each session's last watched second — "where they stopped".
      db
        .prepare(
          `SELECT CAST(m AS INTEGER) AS second, COUNT(*) AS sessions FROM
             (SELECT MAX(video_time) AS m FROM video_events
               WHERE video_id = ? AND type = 'tick' GROUP BY session_id)
            GROUP BY second ORDER BY second`
        )
        .bind(id)
        .all<{ second: number; sessions: number }>(),
      db
        .prepare(
          `SELECT country, COUNT(*) AS count FROM video_views
            WHERE video_id = ? AND country IS NOT NULL
            GROUP BY country ORDER BY count DESC LIMIT 20`
        )
        .bind(id)
        .all<{ country: string; count: number }>(),
      db
        .prepare(
          `SELECT referrer, COUNT(*) AS count FROM video_views
            WHERE video_id = ? AND referrer IS NOT NULL AND referrer != ''
            GROUP BY referrer ORDER BY count DESC LIMIT 20`
        )
        .bind(id)
        .all<{ referrer: string; count: number }>(),
      db
        .prepare(
          `SELECT COUNT(DISTINCT session_id) AS n FROM video_events
            WHERE video_id = ? AND type = 'play'`
        )
        .bind(id)
        .first<{ n: number }>(),
      db
        .prepare(
          `SELECT COUNT(DISTINCT session_id) AS n FROM video_events
            WHERE video_id = ? AND type = 'ended'`
        )
        .bind(id)
        .first<{ n: number }>(),
      db
        .prepare(
          `SELECT COUNT(DISTINCT session_id) AS n FROM video_events
            WHERE video_id = ? AND type = 'cta'`
        )
        .bind(id)
        .first<{ n: number }>(),
    ]);

  // Owner sees comments here regardless of the public comments toggle.
  const comments = await listVideoComments(db, id, 100);

  const stopRows = stops.results ?? [];
  const watchedSessions = stopRows.reduce((a, r) => a + r.sessions, 0);
  const avgWatchedSeconds =
    watchedSessions > 0
      ? stopRows.reduce((a, r) => a + r.second * r.sessions, 0) / watchedSessions
      : 0;

  return c.json({
    videoId: id,
    // For capturecat://open-project?id=…&t=… deep links on comment rows.
    projectId: doc.projectId,
    durationSeconds: doc.durationSeconds,
    views: views?.n ?? 0,
    plays: plays?.n ?? 0,
    completions: completions?.n ?? 0,
    ctaClicks: ctaClicks?.n ?? 0,
    ctaLabel: doc.ctaLabel,
    ctaUrl: doc.ctaUrl,
    avgWatchedSeconds: Math.round(avgWatchedSeconds * 10) / 10,
    watchHeatmap: heatmap.results ?? [],
    dropOff: stopRows,
    clicks: clicks.results ?? [],
    countries: countries.results ?? [],
    referrers: referrers.results ?? [],
    comments: comments.map((cm) => ({
      commentId: cm.commentId,
      authorName: cm.authorName,
      body: cm.body,
      videoTime: cm.videoTime,
      createdAt: cm.createdAt,
    })),
  });
});
