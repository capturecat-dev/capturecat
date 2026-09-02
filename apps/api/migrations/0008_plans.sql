-- Editable plans with per-plan feature gates.
--
-- Plans used to be a single hardcoded `proPlan(env)` in src/lib/stripe.ts, so
-- adding a tier or changing what a tier includes meant a code change and a
-- deploy. @better-auth/stripe accepts `plans` as an async function, so they can
-- come from here instead and the admin console can edit them.
--
-- `features` and `limits` are JSON blobs on purpose: a feature set is a moving
-- target, and a column per feature would mean a migration every time one is
-- added. Enforcement reads specific keys (see lib/plans.ts), so an unknown key
-- is inert rather than dangerous.
CREATE TABLE IF NOT EXISTS plan (
  id            TEXT PRIMARY KEY,
  -- Matches the `plan` name @better-auth/stripe stores on `subscription`.
  -- Renaming one orphans existing subscriptions, so treat it as identity.
  name          TEXT NOT NULL UNIQUE,
  display_name  TEXT NOT NULL,
  description   TEXT,
  price_id      TEXT,
  annual_price_id TEXT,
  trial_days    INTEGER NOT NULL DEFAULT 0,
  -- JSON object: { "webCapture": true, "imageUpload": true, ... }
  features      TEXT NOT NULL DEFAULT '{}',
  -- JSON object: { "maxTotalStorageBytes": 10737418240, ... }
  limits        TEXT NOT NULL DEFAULT '{}',
  sort_order    INTEGER NOT NULL DEFAULT 0,
  is_active     INTEGER NOT NULL DEFAULT 1,
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_plan_active ON plan (is_active, sort_order);

-- The free tier is a row like any other so gating has one code path. It has no
-- price_id and is never sold; it is what `resolveTier` falls back to.
INSERT OR IGNORE INTO plan (id, name, display_name, description, features, limits, sort_order, is_active)
VALUES (
  'plan_free', 'free', 'Free', 'Record and edit locally.',
  '{"webCapture":false,"imageUpload":false,"cloudShare":false,"comments":false,"removeWatermark":false}',
  '{"maxTotalStorageBytes":0,"maxFileSizeBytes":0,"maxDurationSeconds":300,"maxUploadsPerDay":0}',
  0, 1
);

INSERT OR IGNORE INTO plan (id, name, display_name, description, features, limits, sort_order, is_active)
VALUES (
  'plan_pro', 'pro', 'CaptureCat Pro', 'Everything you need to record and share.',
  '{"webCapture":true,"imageUpload":true,"cloudShare":true,"comments":true,"removeWatermark":true}',
  '{"maxTotalStorageBytes":10737418240,"maxFileSizeBytes":1073741824,"maxDurationSeconds":1800,"maxUploadsPerDay":10}',
  1, 1
);
