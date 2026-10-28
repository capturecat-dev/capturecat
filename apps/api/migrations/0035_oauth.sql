-- "Sign in with CaptureCat": OAuth 2.1 for the remote MCP server, so a
-- Claude.ai or ChatGPT custom connector (or any MCP client) connects with a
-- browser consent instead of a pasted token. src/lib/oauth/*, routes/oauth.ts.
--
--   issuer / AS     https://api.capturecat.so   (RFC 8414 metadata)
--   resource / RS   https://mcp.capturecat.so/mcp   (RFC 9728 metadata, RFC 8707)
--   PKCE S256 only; public clients; refresh-token rotation with reuse detection.
--
-- Every credential is opaque, random and stored ONLY as SHA-256, looked up by
-- its public prefix and compared in constant time (the 0033 rule):
--   cc_oac_…  authorization code   10 min, single use
--   cc_oat_…  access token          1 h — an agent_tokens row (below)
--   cc_ort_…  refresh token         30 days, rotated on every use
--   cc_ocs_…  client secret         only for DCR clients that ask for one
-- Additive only.

-- Clients: Dynamic Client Registration (RFC 7591, `kind` = 'dcr', client_id
-- minted here) or a Client ID Metadata Document (`kind` = 'cimd', client_id
-- is the https URL of the document; this row is its cache).
CREATE TABLE IF NOT EXISTS oauth_clients (
  client_id                  TEXT PRIMARY KEY,
  kind                       TEXT NOT NULL,              -- 'dcr' | 'cimd'
  client_name                TEXT NOT NULL,
  client_uri                 TEXT,
  logo_uri                   TEXT,
  redirect_uris              TEXT NOT NULL,              -- JSON array; redirect_uri must match one EXACTLY
  token_endpoint_auth_method TEXT NOT NULL DEFAULT 'none',
  client_secret_hash         TEXT,                       -- SHA-256 of cc_ocs_…; NULL for public clients
  grant_types                TEXT NOT NULL,              -- JSON array
  software_id                TEXT,
  software_version           TEXT,
  created_at                 TEXT NOT NULL,
  fetched_at                 TEXT,                       -- cimd: when the document was last fetched
  last_used_at               TEXT
);

-- One consent = one grant = one refresh-token family. Revoking it (the user's
-- "Revoke" in Settings → Agent access, or refresh-token reuse) revokes every
-- refresh and access token issued under it.
CREATE TABLE IF NOT EXISTS oauth_grants (
  id              TEXT PRIMARY KEY,
  user_id         TEXT NOT NULL,
  client_id       TEXT NOT NULL,
  client_name     TEXT NOT NULL,                         -- as shown at consent
  scopes          TEXT NOT NULL,                         -- JSON array the user allowed
  resource        TEXT NOT NULL,                         -- https://mcp.capturecat.so/mcp
  created_at      TEXT NOT NULL,
  last_used_at    TEXT,
  revoked_at      TEXT,
  revoked_reason  TEXT                                   -- 'user' | 'refresh_reuse' | 'code_reuse' | 'client'
);
CREATE INDEX IF NOT EXISTS idx_oauth_grants_user ON oauth_grants (user_id, client_id);

CREATE TABLE IF NOT EXISTS oauth_codes (
  id              TEXT PRIMARY KEY,
  code_prefix     TEXT NOT NULL,                         -- "cc_oac_" + 8 chars, the lookup key
  code_hash       TEXT NOT NULL,
  client_id       TEXT NOT NULL,
  user_id         TEXT NOT NULL,
  redirect_uri    TEXT NOT NULL,
  code_challenge  TEXT NOT NULL,                         -- S256
  scopes          TEXT NOT NULL,
  resource        TEXT NOT NULL,
  created_at      TEXT NOT NULL,
  expires_at      TEXT NOT NULL,
  used_at         TEXT,
  grant_id        TEXT                                   -- the grant the exchange created (revoked on code reuse)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_oauth_codes_prefix ON oauth_codes (code_prefix);
CREATE INDEX IF NOT EXISTS idx_oauth_codes_expires ON oauth_codes (expires_at);

CREATE TABLE IF NOT EXISTS oauth_refresh_tokens (
  id            TEXT PRIMARY KEY,
  grant_id      TEXT NOT NULL,
  token_prefix  TEXT NOT NULL,                           -- "cc_ort_" + 8 chars
  token_hash    TEXT NOT NULL,
  scopes        TEXT NOT NULL,                           -- may be narrower than the grant's
  created_at    TEXT NOT NULL,
  expires_at    TEXT NOT NULL,
  used_at       TEXT,                                    -- rotated: a second use is REUSE
  revoked_at    TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_oauth_refresh_prefix ON oauth_refresh_tokens (token_prefix);
CREATE INDEX IF NOT EXISTS idx_oauth_refresh_grant ON oauth_refresh_tokens (grant_id);

-- OAuth access tokens are agent_tokens rows, so /mcp authenticates both
-- kinds the same way and every call lands in agent_audit_log under them.
-- Personal tokens (cc_pat_) leave these NULL.
ALTER TABLE agent_tokens ADD COLUMN oauth_client_id TEXT;
ALTER TABLE agent_tokens ADD COLUMN oauth_grant_id TEXT;
ALTER TABLE agent_tokens ADD COLUMN resource TEXT;      -- audience; /mcp refuses any other
CREATE INDEX IF NOT EXISTS idx_agent_tokens_grant ON agent_tokens (oauth_grant_id);
