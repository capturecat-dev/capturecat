-- Cappd D1 schema v1 — replaces the two Firestore collections.
-- Booleans are INTEGER 0/1; timestamps are ISO-8601 TEXT (matching the
-- string values the API already reads/writes).

CREATE TABLE IF NOT EXISTS shared_videos (
  video_id         TEXT PRIMARY KEY,
  uid              TEXT NOT NULL,
  file_name        TEXT NOT NULL,
  content_type     TEXT NOT NULL DEFAULT 'video/mp4',
  file_size_bytes  INTEGER NOT NULL DEFAULT 0,
  duration_seconds REAL NOT NULL DEFAULT 0,
  r2_key           TEXT NOT NULL,
  url              TEXT NOT NULL,
  is_private       INTEGER NOT NULL DEFAULT 0,
  status           TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ready')),
  created_at       TEXT NOT NULL
);

-- Storage-usage sum: WHERE uid = ? AND status = 'ready'
CREATE INDEX IF NOT EXISTS idx_shared_videos_uid_status
  ON shared_videos (uid, status);

CREATE TABLE IF NOT EXISTS stripe_customers (
  uid                TEXT PRIMARY KEY,
  stripe_customer_id TEXT NOT NULL,
  subscription_id    TEXT,
  status             TEXT NOT NULL,
  updated_at         TEXT NOT NULL
);

-- Reverse lookup from Stripe webhooks: WHERE stripe_customer_id = ? LIMIT 1
-- (non-unique to mirror the Firestore query semantics exactly)
CREATE INDEX IF NOT EXISTS idx_stripe_customers_customer
  ON stripe_customers (stripe_customer_id);
