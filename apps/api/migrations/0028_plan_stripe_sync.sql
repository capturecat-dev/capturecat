-- Plans are synced to Stripe on save, and can run a time-limited sale.
--
-- Every column is additive and NULL/0 for existing rows, and the running
-- Worker never reads them, so this is safe to apply to live data before the
-- code that uses it is deployed. See src/lib/stripe-catalog.ts.

-- ONE Stripe product per plan, remembered. The admin "Sync with Stripe"
-- action used to create a new product (and new prices) on every call; it now
-- finds the product by this id (else by its `metadata.plan`, else creates it
-- once) and finds prices by lookup key (`capturecat_<plan>_monthly` /
-- `capturecat_<plan>_yearly`), so a re-sync changes nothing.
ALTER TABLE plan ADD COLUMN stripe_product_id TEXT;

-- A product belongs to at most one plan. Product webhooks (product.updated)
-- are matched on this column, so two plans sharing one would let a rename in
-- the Stripe Dashboard rename both.
CREATE UNIQUE INDEX IF NOT EXISTS idx_plan_stripe_product
  ON plan (stripe_product_id) WHERE stripe_product_id IS NOT NULL;

-- "Most popular": the plan the site features. Display only; at most one (the
-- admin API clears it elsewhere when it is set).
ALTER TABLE plan ADD COLUMN popular INTEGER NOT NULL DEFAULT 0;

-- A time-limited sale ("a price for a period"). Between start (NULL = from
-- saving) and end (required), checkout adds a Stripe coupon that takes the
-- regular price down to the sale price, and the site shows the regular price
-- struck through. Everyone stays on the REGULAR Stripe price; the coupon is
-- the discount, with redeem_by = the sale's end, so Stripe itself refuses it
-- after the sale. Prices in minor units; times ISO-8601 UTC.
ALTER TABLE plan ADD COLUMN sale_label TEXT;
ALTER TABLE plan ADD COLUMN sale_price_monthly_cents INTEGER;
ALTER TABLE plan ADD COLUMN sale_price_annual_cents INTEGER;
ALTER TABLE plan ADD COLUMN sale_starts_at TEXT;
ALTER TABLE plan ADD COLUMN sale_ends_at TEXT;
-- How long the discount lasts for someone who joins during the sale: NULL =
-- for as long as they stay subscribed (coupon `forever`), N = their first N
-- months (coupon `repeating`).
ALTER TABLE plan ADD COLUMN sale_duration_months INTEGER;
-- One coupon per interval, created by the sync. A sale without its coupon is
-- neither charged nor shown.
ALTER TABLE plan ADD COLUMN stripe_sale_coupon_id TEXT;
ALTER TABLE plan ADD COLUMN stripe_sale_annual_coupon_id TEXT;
