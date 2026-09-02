-- Share-page CTA button + dashboard playlists.
--
-- CTA: an owner-set label + URL rendered on the share page; clicks land in
-- video_events as type 'cta' and the analytics endpoint reports the
-- plays → completions → CTA-clicks funnel.
--
-- Playlists: private dashboard organization — emoji-labelled collections a
-- video can belong to (one video may sit in many playlists).

ALTER TABLE shared_videos ADD COLUMN cta_label TEXT;
ALTER TABLE shared_videos ADD COLUMN cta_url TEXT;

CREATE TABLE IF NOT EXISTS video_playlists (
  playlist_id TEXT PRIMARY KEY,
  uid TEXT NOT NULL,
  name TEXT NOT NULL,
  emoji TEXT,
  position INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_video_playlists_uid
  ON video_playlists (uid, position);

CREATE TABLE IF NOT EXISTS playlist_videos (
  playlist_id TEXT NOT NULL,
  video_id TEXT NOT NULL,
  position INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  PRIMARY KEY (playlist_id, video_id)
);

CREATE INDEX IF NOT EXISTS idx_playlist_videos_video
  ON playlist_videos (video_id);
