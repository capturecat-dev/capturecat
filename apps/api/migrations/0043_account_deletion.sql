-- Account deletion (DELETE /api/me, routes/account-delete.ts,
-- lib/account-deletion.ts). App Store Guideline 5.1.1(v): an account made in
-- the app can be deleted in the app.
--
-- Additive only: two new tables, nothing else touched. Numbered after 0042
-- (devices/wireless); production also has 0041 (AI search) — the two are
-- independent and apply in either order.
--
-- The request itself deletes every D1 row the user owns in ONE batch (a
-- transaction), after first copying the R2 keys those rows point at into
-- account_deletion_objects. Removing the bytes is the slow part, so it runs
-- in the background (waitUntil right after the response, then the hourly
-- cron until the queue is empty) and survives an interrupted Worker.

-- 1. One row per deleted account: the background job's state AND the admin
--    audit record. Deliberately no name, no email: `email_hmac` is
--    HMAC-SHA256(BETTER_AUTH_SECRET, lower(email)), enough to answer "was the
--    account for this address deleted, and when?" without keeping the
--    address. `user_id` is the deleted account's id — it names nothing once
--    the user row is gone.
CREATE TABLE IF NOT EXISTS account_deletions (
  id                       TEXT PRIMARY KEY,
  user_id                  TEXT NOT NULL UNIQUE,     -- a second request for the same account is a no-op
  email_hmac               TEXT,
  client                   TEXT NOT NULL,            -- 'ios' | 'mac' | 'web' | 'app' (bearer, unnamed)
  requested_at             TEXT NOT NULL,
  cancelled_subscriptions  INTEGER NOT NULL DEFAULT 0,
  counts_json              TEXT NOT NULL DEFAULT '{}', -- what was removed: {"videos":3,"projects":1,...}
  status                   TEXT NOT NULL DEFAULT 'pending', -- 'pending' (bytes still being removed) | 'done'
  completed_at             TEXT
);
CREATE INDEX IF NOT EXISTS idx_account_deletions_status ON account_deletions (status, requested_at);

-- 2. The background queue: what is left to remove outside D1.
--    kind 'key'          one object in CaptureCat's R2 bucket
--         'prefix'       every object under this prefix in CaptureCat's R2
--                        bucket (listed and deleted 1000 at a time)
--         'cf_hostname'  a Cloudflare for SaaS custom hostname id
--         'cache_video' / 'cache_profile'  a per-colo metadata cache entry
--         'share_jobs'   the user's ShareJobsDO rows
--    Nothing here ever names an object in a customer's OWN bucket
--    (storage_buckets, 0029): those files are theirs, and only the
--    credentials are forgotten.
CREATE TABLE IF NOT EXISTS account_deletion_objects (
  user_id   TEXT NOT NULL,
  kind      TEXT NOT NULL,
  value     TEXT NOT NULL,
  attempts  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, kind, value)
);
