-- The originating editor project of an uploaded video, so the dashboard can
-- deep-link back into the app (capturecat://open-project?id=<uuid>).
-- Nullable: older uploads and non-project sources have none.

ALTER TABLE shared_videos ADD COLUMN project_id TEXT;
