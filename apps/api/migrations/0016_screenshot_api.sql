-- Screenshot-rendering API: per-user access keys + monthly usage metering.
--
-- /api/screenshot/take is a PAID surface (screenshotone-style). Two auth
-- paths reach it: a Better Auth session (the app / dashboard) or one of these
-- keys (third-party / curl use). Keys are stored HASHED — the plaintext is
-- shown exactly once at mint time and cannot be recovered; a leak of this
-- table leaks nothing usable. The token format is
--   cc_live_<id>_<secret>
-- and verification is: look the row up by `id`, then constant-time compare
-- SHA-256(secret) against `key_hash` (see src/lib/screenshot/keys.ts). Lookup
-- by id rather than by hash keeps the comparison genuinely constant-time.
--
-- Revocation is a timestamp, not a DELETE, so the admin console can show a
-- history and a revoked key id can never be silently re-minted into meaning
-- something else.
CREATE TABLE IF NOT EXISTS screenshot_api_keys (
  id          TEXT PRIMARY KEY,               -- public half of the token
  user_id     TEXT NOT NULL,                  -- Better Auth user.id
  key_hash    TEXT NOT NULL,                  -- SHA-256(secret), lowercase hex
  label       TEXT,                           -- user-chosen display name
  created_at  TEXT NOT NULL,
  revoked_at  TEXT                            -- NULL = active
);

CREATE INDEX IF NOT EXISTS idx_screenshot_keys_user ON screenshot_api_keys (user_id);

-- Monthly usage counter, one row per user per calendar month (UTC).
-- Incremented ATOMICALLY by a single conditional upsert (see
-- src/lib/screenshot/quota.ts) — the cap check lives in the SQL's WHERE
-- clause, so two concurrent requests can never both consume the last unit.
CREATE TABLE IF NOT EXISTS screenshot_usage (
  user_id  TEXT NOT NULL,
  yyyymm   TEXT NOT NULL,                     -- e.g. '202608', always UTC
  count    INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, yyyymm)
);

-- Plan gating: `screenshotApi` is a feature key like any other (deny-by-
-- default via FEATURE_DEFAULTS in lib/plans.ts — an old row that omits it
-- denies it), and `maxScreenshotsPerMonth` sits beside the other limits.
-- Free stays denied; Pro gets the feature and a 1000/month cap.
UPDATE plan SET features = json_set(features, '$.screenshotApi', json('true')),
                limits   = json_set(limits, '$.maxScreenshotsPerMonth', 1000),
                updated_at = datetime('now')
WHERE name = 'pro';

UPDATE plan SET features = json_set(features, '$.screenshotApi', json('false')),
                limits   = json_set(limits, '$.maxScreenshotsPerMonth', 0),
                updated_at = datetime('now')
WHERE name = 'free';
