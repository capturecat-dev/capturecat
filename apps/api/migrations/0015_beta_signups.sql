-- Public beta waitlist.
--
-- The /beta page on capturecat.so collects emails; admin.capturecat.so reads
-- this table. Ingest is PUBLIC (the page is public), so the POST route is
-- write-shaped like the analytics ingest: per-IP rate limited, honeypot-gated,
-- Turnstile-verified, and deduped here by the UNIQUE constraint on `email`.
--
-- `email` is stored ALREADY NORMALIZED (lowercased + trimmed by the route) so
-- the UNIQUE index is a case-insensitive dedupe without needing COLLATE. The
-- route uses INSERT OR IGNORE, so a repeat sign-up is a no-op rather than a 500.
--
-- ip / user_agent / referrer / country are forensics for the admin console:
-- they are what lets an operator recognise and delete a burst of junk. They are
-- deliberately nullable — a request behind a stripped proxy still counts.
CREATE TABLE IF NOT EXISTS beta_signups (
  id          TEXT PRIMARY KEY,
  email       TEXT NOT NULL UNIQUE,
  -- Room to grow (e.g. 'invited') without a migration; the route writes 'new'.
  status      TEXT NOT NULL DEFAULT 'new',
  ip          TEXT,
  user_agent  TEXT,
  referrer    TEXT,
  country     TEXT,
  created_at  TEXT NOT NULL
);

-- The admin list pages by newest first.
CREATE INDEX IF NOT EXISTS idx_beta_signups_created ON beta_signups (created_at DESC);
