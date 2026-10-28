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
import { isValidUnlockToken } from "./video";
import { fixedWindowAllow } from "../lib/entitlement";
import { getSharedVideo, listVideoComments } from "../lib/db";
import { requireAuth } from "../middleware/auth";
import { generateId } from "../lib/id";
import { videoAnalytics } from "../lib/video-analytics";
import { backgroundOf, queueWebhookEvent, videoEventData } from "../lib/webhooks";

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
  // Password-gated videos only count viewers who actually unlocked — otherwise
  // anyone could register views (and exhaust a maxViews cap) without the
  // password.
  if (doc.passwordHash && !(await isValidUnlockToken(c.env, doc.videoId, c.req.query("token")))) {
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
  // Global inner layer — the cache counter is per-colo.
  if (!(await fixedWindowAllow(c.env.DB, `ingest:${ip}`, INGEST_RATE_LIMIT, 60))) {
    return c.json({ ok: true }, 202);
  }

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
  // Hard cap on view rows per video: the table is otherwise unbounded from an
  // unauthenticated endpoint (random session ids).
  const MAX_VIEW_ROWS = 200_000;
  const viewRows = await c.env.DB.prepare(
    "SELECT COUNT(*) AS n FROM video_views WHERE video_id = ?"
  ).bind(doc.videoId).first<{ n: number }>();
  if ((viewRows?.n ?? 0) >= MAX_VIEW_ROWS) return c.json({ ok: true }, 202);
  const inserted = await c.env.DB.prepare(
    `INSERT OR IGNORE INTO video_views
       (view_id, video_id, session_id, referrer, country, device, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(generateId(), doc.videoId, sessionId, referrer, cf?.country ?? null, device, now)
    .run();
  // A NEW viewer → share.viewed to the owner's webhooks, at most once per
  // video per 10 minutes, and with nothing about the viewer in it.
  if ((inserted.meta?.changes ?? 0) > 0) {
    queueWebhookEvent(backgroundOf(c), c.env, doc.uid, "share.viewed", videoEventData(c.env, doc), {
      debounceKey: doc.videoId,
    });
  }

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
  const analytics = await videoAnalytics(db, doc);

  // Owner sees comments here regardless of the public comments toggle.
  const comments = await listVideoComments(db, doc.videoId, 100);

  return c.json({
    ...analytics,
    comments: comments.map((cm) => ({
      commentId: cm.commentId,
      authorName: cm.authorName,
      body: cm.body,
      videoTime: cm.videoTime,
      createdAt: cm.createdAt,
    })),
  });
});
