-- Viewer comments on shared videos, plus the per-video opt-in and the
-- annotation markers the share page uses to snap comments to annotations.

ALTER TABLE shared_videos ADD COLUMN comments_enabled INTEGER NOT NULL DEFAULT 0;
-- JSON array of {start, end, label?, autoPause?, pauseDuration?} in OUTPUT
-- (exported-file) seconds. TEXT because D1 has no JSON column type.
ALTER TABLE shared_videos ADD COLUMN annotations_json TEXT;

CREATE TABLE IF NOT EXISTS video_comments (
  comment_id  TEXT PRIMARY KEY,
  video_id    TEXT NOT NULL,
  author_name TEXT NOT NULL,
  body        TEXT NOT NULL,
  -- Seconds into the exported video the comment is anchored to.
  video_time  REAL NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL
);

-- Listing: WHERE video_id = ? ORDER BY video_time
CREATE INDEX IF NOT EXISTS idx_video_comments_video
  ON video_comments (video_id, video_time);
