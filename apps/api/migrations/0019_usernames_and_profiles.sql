-- Public profiles: a claimed username gives a user capturecat.so/{username},
-- listing their public videos.
--
-- `username` is stored lowercase and uniquely indexed; the API validates the
-- charset and a reserved-word list before writing. `profile_visible` lets an
-- owner keep a public share link OFF their profile page — a public link and a
-- listed video are deliberately different things.

ALTER TABLE user ADD COLUMN username TEXT;
ALTER TABLE user ADD COLUMN bio TEXT;
ALTER TABLE user ADD COLUMN website TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_username ON user (username);

ALTER TABLE shared_videos ADD COLUMN profile_visible INTEGER NOT NULL DEFAULT 1;
