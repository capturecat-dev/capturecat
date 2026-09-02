-- Hub batch 2: time-anchored emoji reactions, transcripts, AI summaries and
-- custom share domains.

-- Viewer reactions, anchored to a second of the video. No auth — same trust
-- model as comments; rate limits + per-video caps bound abuse.
CREATE TABLE IF NOT EXISTS video_reactions (
  reaction_id TEXT PRIMARY KEY,
  video_id    TEXT NOT NULL,
  -- Random per-tab id, same one the analytics beacon mints.
  session_id  TEXT NOT NULL,
  emoji       TEXT NOT NULL,
  video_time  REAL NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_video_reactions_video
  ON video_reactions (video_id, video_time);

-- Transcript segments (from the app's on-device subtitles), plus the flat
-- text for LIKE search across a user's library.
CREATE TABLE IF NOT EXISTS video_transcripts (
  video_id      TEXT PRIMARY KEY,
  uid           TEXT NOT NULL,
  -- JSON array of {start, end, text} in output-time seconds.
  segments_json TEXT NOT NULL,
  -- Lower-cased concatenation of all segment text, for search.
  full_text     TEXT NOT NULL,
  created_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_video_transcripts_uid
  ON video_transcripts (uid);

-- AI title/summary/chapters for the share page. `ai_source` records whether
-- the app's local model or server-side Gemini produced them.
ALTER TABLE shared_videos ADD COLUMN ai_title TEXT;
ALTER TABLE shared_videos ADD COLUMN ai_summary TEXT;
ALTER TABLE shared_videos ADD COLUMN ai_chapters_json TEXT;
ALTER TABLE shared_videos ADD COLUMN ai_source TEXT;

-- Custom share domains (Pro-gated). One domain maps to one user; share pages
-- resolve <domain>/<videoId>. `verified` flips after the CNAME check passes.
CREATE TABLE IF NOT EXISTS custom_domains (
  domain     TEXT PRIMARY KEY,
  uid        TEXT NOT NULL,
  verified   INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_custom_domains_uid
  ON custom_domains (uid);
