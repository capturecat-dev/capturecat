-- Agent features, phase 2: plan gates + "ask me first" approvals.
--
-- 1. Plan feature flags (lib/plans.ts FEATURE_KEYS):
--      agentAccess    agent tokens, OAuth connectors, the remote MCP server
--      agentWebhooks  signed webhooks to the user's own endpoints
--      agentEditing   cloud-project editing tools on the remote MCP server
--    A plan row without a key reads it as FALSE (deny by default), so without
--    this UPDATE every existing user would lose agent access the moment the
--    gate ships. Turning all three on for EVERY existing plan row preserves
--    today's behaviour; the owner then switches them off per plan in the admin
--    console. Rows whose JSON is unreadable already deny everything and are
--    left alone (json_set would fail on them).
UPDATE plan
   SET features = json_set(
         features,
         '$.agentAccess', json('true'),
         '$.agentWebhooks', json('true'),
         '$.agentEditing', json('true')
       )
 WHERE json_valid(features);

-- 2. Approvals (lib/agent-approvals.ts). An agent must ask before it makes a
--    video viewable to more people or posts where viewers see it. The gated
--    tool call answers `approval_required` with a link; the human approves or
--    denies in the web app (session only — no agent credential can decide);
--    the agent repeats the SAME call with approval_id, which runs exactly once.
--
--    args_json is the canonical JSON of the tool arguments (sorted keys,
--    approval_id removed, secrets such as a new share password replaced by
--    their SHA-256), so a repeat with different arguments is refused.
--    status: pending → approved | denied | expired;  approved → used | expired.
--    expires_at: 15 minutes after the request; reset to 15 minutes after an
--    approval, the window the agent has to use it.
CREATE TABLE IF NOT EXISTS agent_approvals (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL,
  token_id    TEXT NOT NULL,          -- agent_tokens.id that asked (PAT or OAuth access token)
  tool        TEXT NOT NULL,          -- MCP tool name
  args_json   TEXT NOT NULL,          -- canonical arguments
  summary     TEXT NOT NULL,          -- one human-readable line
  details     TEXT,                   -- JSON array of change lines shown on the approval page
  video_id    TEXT,                   -- the video it concerns, if any
  status      TEXT NOT NULL DEFAULT 'pending',
  created_at  TEXT NOT NULL,
  decided_at  TEXT,
  expires_at  TEXT NOT NULL,
  used_at     TEXT
);

CREATE INDEX IF NOT EXISTS idx_agent_approvals_user ON agent_approvals (user_id, status, created_at);
CREATE INDEX IF NOT EXISTS idx_agent_approvals_created ON agent_approvals (created_at);
