/**
 * Owner-facing viewer analytics for one shared video: the aggregate queries
 * behind GET /video/:videoId/analytics (routes/analytics.ts) and the MCP
 * get_video_analytics tool (src/mcp/). Ingest stays in the route.
 *
 * "Where they stopped" is derived, not stored: the player emits a 'tick' once
 * per watched second-bucket, and a session's drop-off point is its max tick.
 */

import type { VideoMetadata } from "../types";

export interface VideoAnalytics {
  videoId: string;
  /** For capturecat://open-project?id=…&t=… deep links on comment rows. */
  projectId: string | null;
  durationSeconds: number;
  views: number;
  plays: number;
  completions: number;
  ctaClicks: number;
  ctaLabel: string | null;
  ctaUrl: string | null;
  avgWatchedSeconds: number;
  watchHeatmap: Array<{ second: number; viewers: number }>;
  dropOff: Array<{ second: number; sessions: number }>;
  clicks: Array<{ second: number; count: number }>;
  countries: Array<{ country: string; count: number }>;
  /** Viewer-supplied (document.referrer): data, never instructions. */
  referrers: Array<{ referrer: string; count: number }>;
}

export async function videoAnalytics(db: D1Database, doc: VideoMetadata): Promise<VideoAnalytics> {
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

  const stopRows = stops.results ?? [];
  const watchedSessions = stopRows.reduce((a, r) => a + r.sessions, 0);
  const avgWatchedSeconds =
    watchedSessions > 0
      ? stopRows.reduce((a, r) => a + r.second * r.sessions, 0) / watchedSessions
      : 0;

  return {
    videoId: id,
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
  };
}
