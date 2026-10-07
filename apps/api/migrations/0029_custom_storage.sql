-- Bring-your-own bucket for share videos (lib/storage.ts, routes/storage.ts).
--
-- A user connects an S3-compatible bucket (AWS S3, R2, B2, Wasabi, MinIO…);
-- new share uploads are presigned into it, and the share page plays them by a
-- gated redirect to the customer's bucket. Additive only: every existing row
-- has storage_id NULL, which means "CaptureCat's own R2 bucket", so this is
-- safe to apply before the code that reads it is deployed.

-- One row per bucket a user has connected. `active` marks the one new uploads
-- go to (at most one per user). A disconnected bucket that still holds share
-- videos stays as an inactive row: playback and deletion need its credentials.
-- The secret access key is AES-GCM encrypted with STORAGE_CREDENTIALS_KEY
-- (never stored or returned in clear).
CREATE TABLE IF NOT EXISTS storage_buckets (
  id                TEXT PRIMARY KEY,
  uid               TEXT NOT NULL,
  provider          TEXT NOT NULL,             -- aws | r2 | b2 | wasabi | minio | other
  endpoint          TEXT,                      -- NULL = AWS regional endpoint
  region            TEXT NOT NULL,
  bucket            TEXT NOT NULL,
  path_prefix       TEXT NOT NULL DEFAULT '',  -- '' or ends with '/'
  force_path_style  INTEGER NOT NULL DEFAULT 0,
  public_base_url   TEXT,                      -- NULL = serve by presigned GET
  access_key_id     TEXT NOT NULL,
  secret_ciphertext TEXT NOT NULL,             -- base64(iv || AES-GCM ciphertext)
  active            INTEGER NOT NULL DEFAULT 1,
  verified_at       TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_storage_buckets_uid ON storage_buckets (uid);
CREATE UNIQUE INDEX IF NOT EXISTS idx_storage_buckets_one_active
  ON storage_buckets (uid) WHERE active = 1;

-- Where each file lives. NULL = CaptureCat R2. The version row is the truth;
-- shared_videos.storage_id mirrors the CURRENT version the same way r2_key
-- does (setCurrentVersion copies both), so the stream route needs no join.
ALTER TABLE video_versions ADD COLUMN storage_id TEXT;
ALTER TABLE shared_videos ADD COLUMN storage_id TEXT;

-- The gate: every PAID plan includes it; free never does (deny by default —
-- a plan row without the key reads false). Self-hosted instances own their
-- plan rows and can tick "Custom storage" on any plan in their admin console.
UPDATE plan
   SET features = json_set(features, '$.customStorage', json('true'))
 WHERE name IN ('pro', 'business');
