-- Where users and site visitors come from.
--
-- Nothing here is a cookie or a stored identifier: the privacy policy promises
-- a single essential cookie, so attribution is captured in page memory on the
-- landing load and sent with the events that happen in that same page session.
-- Referrers are stored as a bare host and only utm_* tags are kept from the
-- query string — never a full URL. Channels (chatgpt, google, reddit, …) are
-- classified at READ time by src/lib/traffic-source.ts, so improving the
-- classifier reclassifies history too.

-- 1. Sign-up attribution, written once by the user.create.after hook in
--    src/lib/auth.ts. Plain columns, NOT Better Auth additionalFields: they
--    never travel to a client in the session payload, and no client body can
--    reach them. NULL on users created before this migration.
ALTER TABLE user ADD COLUMN signupCountry  TEXT;   -- ISO-3166 alpha-2 of the OAuth callback request (Cloudflare geo)
ALTER TABLE user ADD COLUMN signupVia      TEXT;   -- 'web' | 'desktop' (the Mac app's loopback sign-in)
ALTER TABLE user ADD COLUMN signupReferrer TEXT;   -- external referrer host of the landing visit, when known
ALTER TABLE user ADD COLUMN signupUtm      TEXT;   -- "source|medium|campaign" of the landing visit, when known
ALTER TABLE user ADD COLUMN signupLanding  TEXT;   -- first path seen on capturecat.so, when known

-- 2. Anonymous site events from capturecat.so. One 'visit' per page session
--    (reloads and back/forward are skipped client-side); 'download' carries
--    the attribution of the visit it happened in. No IP, no UA string, no id.
CREATE TABLE IF NOT EXISTS site_events (
  id            TEXT PRIMARY KEY,
  type          TEXT NOT NULL,     -- 'visit' | 'download'
  created_at    TEXT NOT NULL,
  referrer_host TEXT,              -- NULL = no external referrer (typed, bookmarked, app link, stripped)
  utm_source    TEXT,
  utm_medium    TEXT,
  utm_campaign  TEXT,
  landing_path  TEXT,              -- /share/<id> is stored as /share/* (ids are capabilities)
  country       TEXT,
  device        TEXT,              -- 'mac' | 'windows' | 'ios' | 'android' | 'linux' | 'other'
  detail        TEXT               -- download: 'arm64' | 'x86_64'
);
CREATE INDEX IF NOT EXISTS idx_site_events_created ON site_events (created_at, type);
