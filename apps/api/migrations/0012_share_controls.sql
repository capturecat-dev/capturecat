-- Share-page controls: download button, protected links, and per-video brand
-- accent. All nullable/defaulted so existing rows keep behaving identically.

-- Viewers may download the original file from the share page.
ALTER TABLE shared_videos ADD COLUMN allow_download INTEGER NOT NULL DEFAULT 0;

-- SHA-256("<videoId>:<password>") hex, NULL = no password gate.
ALTER TABLE shared_videos ADD COLUMN password_hash TEXT;

-- ISO date after which the share page refuses to play. NULL = never.
ALTER TABLE shared_videos ADD COLUMN expires_at TEXT;

-- Maximum distinct viewer sessions (video_views rows). NULL/0 = unlimited.
ALTER TABLE shared_videos ADD COLUMN max_views INTEGER;

-- Owner brand accent for the share page chrome, "#RRGGBB". NULL = default.
ALTER TABLE shared_videos ADD COLUMN brand_accent TEXT;
