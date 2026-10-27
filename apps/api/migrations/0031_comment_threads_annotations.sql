-- Share-page comments, round two: one-level threads, on-frame annotations and
-- signed-in commenter identity. Additive only — every pre-0031 row keeps all
-- four columns NULL and renders exactly as before (top-level, no drawing,
-- initial-circle avatar, never marked as the owner).

-- The top-level comment this row replies to. NULL = a top-level comment.
-- Only one level deep: the API refuses a reply whose target is itself a
-- reply, or a target on a different video.
ALTER TABLE video_comments ADD COLUMN parent_id TEXT;

-- Canonical JSON of the on-frame annotation: {"v":1,"shapes":[…]}, every
-- coordinate normalized 0–1 to the video frame. Written only after the strict
-- validator in src/lib/comments.ts has rebuilt it (kinds allowlist, caps on
-- shapes / points / text, ≤ 32 KB). NULL = no drawing.
ALTER TABLE video_comments ADD COLUMN annotation_json TEXT;

-- The commenter's Better Auth user id when they were signed in. Never sent to
-- the browser: it only decides `isOwner` (author_uid = shared_videos.uid).
ALTER TABLE video_comments ADD COLUMN author_uid TEXT;

-- Avatar URL copied FROM THE SESSION (user.image) at post time — never from
-- the request body, so a viewer cannot point the page at an arbitrary URL.
ALTER TABLE video_comments ADD COLUMN author_image TEXT;

-- Per-thread reply count (the reply cap) and "is this id a top-level comment
-- on this video" lookups.
CREATE INDEX IF NOT EXISTS idx_video_comments_parent
  ON video_comments (parent_id)
  WHERE parent_id IS NOT NULL;

-- Account clean-up: find a user's signed-in comments.
CREATE INDEX IF NOT EXISTS idx_video_comments_author
  ON video_comments (author_uid)
  WHERE author_uid IS NOT NULL;
