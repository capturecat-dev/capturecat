-- Agent tokens: scoped, revocable credentials for cloud agents (a Claude.ai
-- connector, Claude Code over HTTP, ChatGPT, a scheduled agent) calling the
-- remote MCP server at https://mcp.capturecat.so/mcp. Generalizes the
-- Screenshot API's access keys (0016) to the rest of the account.
--
-- Token format (src/lib/agent-tokens.ts):  cc_pat_<40 × [A-Za-z0-9]>
-- Only SHA-256(token) is stored. `token_prefix` is "cc_pat_" plus the first
-- 8 random characters: the public half, shown in the dashboard and used as
-- the lookup key, so verification can look the row up by prefix and then
-- compare hashes in constant time (the same reasoning as 0016's id + secret).
--
-- A token never carries more than its user has: scopes only NARROW what the
-- token may touch, and every tool still resolves the user's plan per call.
-- There are deliberately no billing, admin or delete scopes.
--
-- Revocation is a timestamp, not a DELETE, so the audit log keeps naming the
-- token that acted. Additive only.
CREATE TABLE IF NOT EXISTS agent_tokens (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL,                -- Better Auth user.id
  name          TEXT NOT NULL,                -- user-chosen label
  token_hash    TEXT NOT NULL,                -- SHA-256(full token), lowercase hex
  token_prefix  TEXT NOT NULL,                -- "cc_pat_" + first 8 chars, public
  scopes        TEXT NOT NULL,                -- JSON array of scope strings
  created_at    TEXT NOT NULL,                -- ISO-8601
  expires_at    TEXT,                         -- ISO-8601; NULL = never
  last_used_at  TEXT,                         -- ISO-8601; written at most once a minute
  revoked_at    TEXT                          -- ISO-8601; NULL = active
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_tokens_prefix ON agent_tokens (token_prefix);
CREATE INDEX IF NOT EXISTS idx_agent_tokens_user ON agent_tokens (user_id, created_at);

-- One row per MCP tool call, success or not. `tool` is the MCP tool name (or
-- a route, for future non-MCP agent calls). Swept after 90 days (index.ts).
CREATE TABLE IF NOT EXISTS agent_audit_log (
  id        TEXT PRIMARY KEY,
  user_id   TEXT NOT NULL,
  token_id  TEXT NOT NULL,
  tool      TEXT NOT NULL,
  video_id  TEXT,                             -- the video acted on, if any
  ok        INTEGER NOT NULL,                 -- 1 = succeeded, 0 = refused/failed
  error     TEXT,                             -- short message when ok = 0
  at        TEXT NOT NULL                     -- ISO-8601
);

CREATE INDEX IF NOT EXISTS idx_agent_audit_user ON agent_audit_log (user_id, at);
CREATE INDEX IF NOT EXISTS idx_agent_audit_token ON agent_audit_log (token_id, at);
CREATE INDEX IF NOT EXISTS idx_agent_audit_at ON agent_audit_log (at);
