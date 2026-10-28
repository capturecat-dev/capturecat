-- Webhooks: signed POSTs to endpoints the user registers (lib/webhooks.ts,
-- routes/webhooks.ts, the MCP tools list_webhooks / create_webhook).
-- Gated by the plan's agentWebhooks flag.
--
-- Standard Webhooks (https://www.standardwebhooks.com): headers webhook-id,
-- webhook-timestamp and webhook-signature ("v1,<base64 HMAC-SHA256 over
-- id.timestamp.body>") keyed by a `whsec_…` secret. The secret is stored
-- AES-GCM encrypted (key derived from BETTER_AUTH_SECRET, id + user as AAD)
-- and shown to the user once.
--
-- Events: video.ready, comment.created, share.viewed (≤ 1 per video per
-- 10 min), project.saved, upload.failed — plus webhook.test from the
-- Settings "Send test" button.
CREATE TABLE IF NOT EXISTS webhook_endpoints (
  id               TEXT PRIMARY KEY,
  user_id          TEXT NOT NULL,
  url              TEXT NOT NULL,                     -- https only, public hosts only (SSRF guard)
  description      TEXT,
  secret           TEXT NOT NULL,                     -- base64(iv || AES-GCM(whsec_…))
  events           TEXT NOT NULL,                     -- JSON array of event names
  active           INTEGER NOT NULL DEFAULT 1,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL,
  created_by_token TEXT,                              -- agent_tokens.id when an agent created it
  last_success_at  TEXT,
  last_failure_at  TEXT,
  failure_count    INTEGER NOT NULL DEFAULT 0,        -- CONSECUTIVE failed attempts
  failing_since    TEXT,                              -- first failure of the current streak
  disabled_reason  TEXT                               -- set when the failure streak switched it off
);
CREATE INDEX IF NOT EXISTS idx_webhook_endpoints_user ON webhook_endpoints (user_id, active);

-- The outbox. A row is written per (event, endpoint) when the event happens,
-- attempted at once (ctx.waitUntil), then by the */5 cron with exponential
-- backoff until it is delivered or gives up. `next_attempt_at` doubles as a
-- lease: a sender claims a row by pushing it a couple of minutes out.
--   status: pending → delivered | failed (gave up) | cancelled (endpoint gone or off)
CREATE TABLE IF NOT EXISTS webhook_deliveries (
  id               TEXT PRIMARY KEY,                  -- msg_…, also the webhook-id header
  endpoint_id      TEXT NOT NULL,
  user_id          TEXT NOT NULL,
  event            TEXT NOT NULL,
  payload          TEXT NOT NULL,                     -- the exact JSON body that is signed and sent
  attempt          INTEGER NOT NULL DEFAULT 0,        -- attempts made so far
  next_attempt_at  TEXT,                              -- NULL once final
  status           TEXT NOT NULL DEFAULT 'pending',
  response_code    INTEGER,
  error            TEXT,
  created_at       TEXT NOT NULL,
  last_attempt_at  TEXT,
  delivered_at     TEXT
);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_due ON webhook_deliveries (status, next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_endpoint ON webhook_deliveries (endpoint_id, created_at);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_created ON webhook_deliveries (created_at);
