-- Moderation: the admin console's Videos page (admin.capturecat.so →
-- /admin/videos, routes/admin-moderation.ts) lists every upload, viewers
-- report bad content from share pages (POST /api/video/:id/report), and an
-- admin can take a video down, restore it, or delete it for good.
--
-- Additive only: three nullable columns on shared_videos, two new tables.
--
--   removed_at      NULL = live. Set = taken down by an admin: every public
--                   surface (share page, embed, stream, download, comments,
--                   thumbnail, analytics, profile) answers "removed"; the file
--                   is KEPT so the takedown can be undone. Survives re-uploads
--                   of new versions — only an admin restores.
--   removed_reason  Shown to the owner in their dashboard.
--   removed_by      user.id of the admin who took it down.
ALTER TABLE shared_videos ADD COLUMN removed_at TEXT;
ALTER TABLE shared_videos ADD COLUMN removed_reason TEXT;
ALTER TABLE shared_videos ADD COLUMN removed_by TEXT;

-- The admin list: every upload, newest first, keyset-paged on (created_at, video_id).
CREATE INDEX IF NOT EXISTS idx_shared_videos_created
  ON shared_videos (created_at DESC, video_id DESC);

-- One row per viewer report. The reporter is identified only by an HMAC of
-- their IP (and their user id when signed in) — enough to keep one open
-- report per person per video, never the IP itself.
--   reason      spam | sexual | violence | hate | harassment | illegal | copyright | other
--               (persistence identity — never renamed; the API's zod enum is the gate)
--   resolution  NULL while open; 'removed' (the video was taken down) or 'dismissed'
CREATE TABLE IF NOT EXISTS video_reports (
  id             TEXT PRIMARY KEY,
  video_id       TEXT NOT NULL,
  reason         TEXT NOT NULL,
  details        TEXT,
  reporter_hash  TEXT NOT NULL,
  reporter_uid   TEXT,
  created_at     TEXT NOT NULL,
  resolved_at    TEXT,
  resolution     TEXT
);

CREATE INDEX IF NOT EXISTS idx_video_reports_video
  ON video_reports (video_id, created_at DESC);
-- The "Reported" queue: open reports, newest first.
CREATE INDEX IF NOT EXISTS idx_video_reports_open
  ON video_reports (created_at DESC)
  WHERE resolved_at IS NULL;

-- Audit trail of every moderation action, kept after a video is deleted.
--   action  remove | restore | delete | dismiss
CREATE TABLE IF NOT EXISTS moderation_actions (
  id          TEXT PRIMARY KEY,
  video_id    TEXT NOT NULL,
  video_owner TEXT,
  admin_uid   TEXT NOT NULL,
  action      TEXT NOT NULL,
  reason      TEXT,
  created_at  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_moderation_actions_video
  ON moderation_actions (video_id, created_at DESC);
