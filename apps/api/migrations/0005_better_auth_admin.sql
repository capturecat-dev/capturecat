-- Better Auth `admin` plugin schema.
--
-- Adds role-based admin authority so admin-ness is a property of the user row
-- that can be granted from the UI, rather than an ADMIN_EMAILS env var that
-- needs a redeploy to change.
--
-- `banned`/`banReason`/`banExpires` are created because the plugin's schema
-- requires them, but they are NOT the blocking mechanism: `user.blocked`
-- remains the single source of truth, because `resolveTier()` and GET /api/me
-- already derive the "blocked" tier from it and the desktop client depends on
-- that contract. The plugin's ban/unban endpoints are denied at the router
-- (src/index.ts) so the two can never disagree.

ALTER TABLE user ADD COLUMN role TEXT;
ALTER TABLE user ADD COLUMN banned INTEGER;
ALTER TABLE user ADD COLUMN banReason TEXT;
ALTER TABLE user ADD COLUMN banExpires TEXT;

ALTER TABLE session ADD COLUMN impersonatedBy TEXT;

-- Admin lookups filter on role; everything else pages by createdAt.
CREATE INDEX IF NOT EXISTS idx_user_role ON user (role);
