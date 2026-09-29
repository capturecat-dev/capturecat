-- 1. Every non-video object a user stores in R2 is recorded here so
--    storageUsageBytes() can count it. Screenshots stored via
--    /api/screenshot/take?store=true were previously invisible to the quota.
CREATE TABLE IF NOT EXISTS stored_objects (
  r2_key     TEXT PRIMARY KEY,
  uid        TEXT NOT NULL,
  kind       TEXT NOT NULL,            -- 'screenshot'
  bytes      INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_stored_objects_uid ON stored_objects (uid);

-- 2. Cloudflare for SaaS custom hostname bookkeeping. `verified` keeps its
--    meaning (DNS points at us) but the share host only ROUTES once Cloudflare
--    reports the hostname and its certificate active.
ALTER TABLE custom_domains ADD COLUMN cf_hostname_id TEXT;
ALTER TABLE custom_domains ADD COLUMN cf_status TEXT;
ALTER TABLE custom_domains ADD COLUMN cf_ssl_status TEXT;
ALTER TABLE custom_domains ADD COLUMN cf_checked_at TEXT;

-- 3. The Business tier: everything in Pro plus SSO and a pooled storage cap.
--    Seeded INACTIVE with no price: run "Stripe sync" in the admin console,
--    then activate it. Nothing is sellable until then, and `sso` stays off on
--    every active plan, so this migration changes no live entitlement.
INSERT OR IGNORE INTO plan (id, name, display_name, description, features, limits, sort_order, is_active)
VALUES (
  'plan_business', 'business', 'CaptureCat Business',
  'For teams: shared library, enterprise SSO, and more storage.',
  '{"webCapture":true,"imageUpload":true,"cloudShare":true,"comments":true,"removeWatermark":true,"customDomain":true,"aiSummaries":true,"screenshotApi":true,"teams":true,"sso":true}',
  '{"maxTotalStorageBytes":107374182400,"maxFileSizeBytes":2147483648,"maxDurationSeconds":3600,"maxUploadsPerDay":50,"maxScreenshotsPerMonth":5000}',
  2, 0
);

-- 4. SSO sign-in looks providers up by email domain on every attempt.
CREATE INDEX IF NOT EXISTS idx_sso_provider_domain ON "ssoProvider" ("domain");
CREATE INDEX IF NOT EXISTS idx_sso_provider_org ON "ssoProvider" ("organizationId");
