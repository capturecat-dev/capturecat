-- Changelog: entries the owner writes in the admin console (admin.capturecat.so
-- → /admin/changelog, routes/changelog.ts) and the public site shows at
-- capturecat.so/changelog, /changelog.md and /changelog.xml (GET /api/changelog).
--
-- Additive only: one new table, nothing else touched.
--
--   published_at  NULL = draft (never served publicly). A date in the future is
--                 a scheduled entry: the public routes serve only
--                 published_at <= now, so it appears by itself when the time comes.
--   category      new | improved | fixed | security
--   platforms     JSON array of mac | web | api | agents (may be empty)
--   body          Markdown, rendered by the site's escaped renderer
--                 (apps/web/src/lib/changelog/markdown.tsx) — raw HTML is shown
--                 as text, never injected.
--
-- No CHECK constraints on category/platforms on purpose: SQLite cannot alter a
-- CHECK without rebuilding the table, so a new category would need a copy
-- migration. The API's zod schema is the gate; these values are persistence
-- identity, so they are never renamed.
CREATE TABLE IF NOT EXISTS changelog_entries (
  id            TEXT PRIMARY KEY,
  slug          TEXT NOT NULL UNIQUE,              -- URL: /changelog/<slug>
  title         TEXT NOT NULL,
  summary       TEXT NOT NULL,                     -- one line: lists, RSS, meta description
  body          TEXT NOT NULL DEFAULT '',          -- Markdown
  category      TEXT NOT NULL,
  platforms     TEXT NOT NULL DEFAULT '[]',
  version       TEXT,                              -- e.g. "1.3.1"; NULL when not tied to a release
  published_at  TEXT,                              -- ISO 8601; NULL = draft
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  created_by    TEXT                               -- user.id of the admin who wrote it
);

-- The public feed: published entries, newest first, keyset-paged on (published_at, id).
CREATE INDEX IF NOT EXISTS idx_changelog_entries_published
  ON changelog_entries (published_at DESC, id DESC)
  WHERE published_at IS NOT NULL;
