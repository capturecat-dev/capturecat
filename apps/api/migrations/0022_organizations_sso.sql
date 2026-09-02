-- Teams + SSO: Better Auth organization plugin + @better-auth/sso tables,
-- plus org scoping on shared media.
--
-- Table/column names come from the plugins' own schema dumps (organization,
-- member, invitation, session.activeOrganizationId, ssoProvider) — same
-- camelCase-quoted convention as 0003_better_auth.sql. `date` columns hold
-- ISO-8601 TEXT, booleans hold 0/1 (adapter runs supportsDates:false).

CREATE TABLE IF NOT EXISTS "organization" (
  "id"        text NOT NULL PRIMARY KEY,
  "name"      text NOT NULL,
  "slug"      text NOT NULL UNIQUE,
  "logo"      text,
  "createdAt" date NOT NULL,
  "metadata"  text
);

CREATE TABLE IF NOT EXISTS "member" (
  "id"             text NOT NULL PRIMARY KEY,
  "organizationId" text NOT NULL REFERENCES "organization" ("id") ON DELETE CASCADE,
  "userId"         text NOT NULL REFERENCES "user" ("id") ON DELETE CASCADE,
  "role"           text NOT NULL DEFAULT 'member',
  "createdAt"      date NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_member_org  ON "member" ("organizationId");
CREATE INDEX IF NOT EXISTS idx_member_user ON "member" ("userId");

CREATE TABLE IF NOT EXISTS "invitation" (
  "id"             text NOT NULL PRIMARY KEY,
  "organizationId" text NOT NULL REFERENCES "organization" ("id") ON DELETE CASCADE,
  "email"          text NOT NULL,
  "role"           text,
  "status"         text NOT NULL DEFAULT 'pending',
  "expiresAt"      date NOT NULL,
  "createdAt"      date NOT NULL,
  "inviterId"      text NOT NULL REFERENCES "user" ("id") ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_invitation_org ON "invitation" ("organizationId");

-- Session gains the active-organization pointer.
ALTER TABLE "session" ADD COLUMN "activeOrganizationId" text;

CREATE TABLE IF NOT EXISTS "ssoProvider" (
  "id"             text NOT NULL PRIMARY KEY,
  "issuer"         text NOT NULL,
  "oidcConfig"     text,
  "samlConfig"     text,
  "userId"         text REFERENCES "user" ("id") ON DELETE CASCADE,
  "providerId"     text NOT NULL UNIQUE,
  "organizationId" text,
  "domain"         text NOT NULL,
  "domainVerified" integer
);

-- Org scoping for shared media: NULL = personal (today's behavior).
ALTER TABLE shared_videos   ADD COLUMN org_id TEXT;
ALTER TABLE video_playlists ADD COLUMN org_id TEXT;
CREATE INDEX IF NOT EXISTS idx_shared_videos_org ON shared_videos (org_id, created_at);
