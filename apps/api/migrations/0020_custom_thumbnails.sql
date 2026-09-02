-- Custom share thumbnails (owner-uploaded poster images).
--
-- The image itself lives in R2 at `thumbs/{videoId}`; this column records
-- that one exists and which content type it was stored with (image/jpeg,
-- image/png or image/webp). NULL = no custom thumbnail — the dashboard and
-- share page fall back to decoding a video frame.

ALTER TABLE shared_videos ADD COLUMN thumbnail_type TEXT;
