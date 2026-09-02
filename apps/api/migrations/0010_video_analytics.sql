-- Viewer analytics for shared videos: views, watch progress (drop-off) and
-- interaction events, written by the public share page in beacon batches.

CREATE TABLE IF NOT EXISTS video_views (
  view_id    TEXT PRIMARY KEY,
  video_id   TEXT NOT NULL,
  -- Random per-tab id minted by the player; NOT a tracking cookie.
  session_id TEXT NOT NULL,
  referrer   TEXT,
  country    TEXT,
  device     TEXT,
  created_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_video_views_session
  ON video_views (video_id, session_id);
CREATE INDEX IF NOT EXISTS idx_video_views_video
  ON video_views (video_id, created_at);

CREATE TABLE IF NOT EXISTS video_events (
  event_id   TEXT PRIMARY KEY,
  video_id   TEXT NOT NULL,
  session_id TEXT NOT NULL,
  -- 'tick' (watched second bucket), 'play', 'pause', 'seek', 'ended', 'click'
  type       TEXT NOT NULL,
  -- Seconds into the exported video the event refers to.
  video_time REAL NOT NULL DEFAULT 0,
  -- Optional JSON payload (e.g. click target).
  meta       TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_video_events_video
  ON video_events (video_id, type, video_time);
