-- Video version history (replace-in-place shares).
--
-- A re-share of an already-shared project no longer mints a new videoId/link:
-- the new file uploads to a versioned R2 key (videos/{id}/v{n}.mp4) and the
-- shared_videos row flips its current_version / r2_key while the URL stays.
-- Old files are kept as history rows the owner can restore, delete, or expose
-- on the share page (show_version_history).

CREATE TABLE IF NOT EXISTS video_versions (
  version_id TEXT PRIMARY KEY,
  video_id TEXT NOT NULL,
  version_number INTEGER NOT NULL,
  r2_key TEXT NOT NULL,
  file_size_bytes INTEGER NOT NULL DEFAULT 0,
  duration_seconds REAL NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ready')),
  created_at TEXT NOT NULL,
  UNIQUE (video_id, version_number)
);

CREATE INDEX IF NOT EXISTS idx_video_versions_video
  ON video_versions (video_id, version_number);

ALTER TABLE shared_videos ADD COLUMN current_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE shared_videos ADD COLUMN show_version_history INTEGER NOT NULL DEFAULT 0;

-- Backfill: every existing ready video becomes version 1 of itself, keyed by
-- its current r2_key. (Storage accounting sums video_versions when rows exist,
-- shared_videos otherwise — see storageUsageBytes.)
INSERT INTO video_versions (
  version_id, video_id, version_number, r2_key,
  file_size_bytes, duration_seconds, status, created_at
)
SELECT
  'v1-' || video_id, video_id, 1, r2_key,
  file_size_bytes, duration_seconds, 'ready', created_at
FROM shared_videos
WHERE status = 'ready';
