-- Plans assigned by an admin (the console's "Assign plan").
--
-- Paid access still has ONE source of truth: the `subscription` table, which
-- @better-auth/stripe keeps in step with Stripe. An assigned plan is a real
-- Stripe subscription on the plan's price with a 100%-off "complimentary"
-- coupon (see 0007 — comps are a Stripe operation, never a local flag), so
-- resolveTier() and every feature gate treat it exactly like a paid plan.
--
-- This table is the record of WHO granted it, when and until when — the
-- audit trail Stripe metadata alone would bury — and how the console tells a
-- complimentary plan from a customer who pays (which it must never cancel).
-- Additive only.
CREATE TABLE IF NOT EXISTS plan_grants (
  id                     TEXT PRIMARY KEY,
  user_id                TEXT NOT NULL,
  plan                   TEXT NOT NULL,      -- plan.name (lowercase), as on the subscription row
  stripe_subscription_id TEXT NOT NULL,
  granted_by             TEXT NOT NULL,      -- the admin's user id
  granted_at             TEXT NOT NULL,      -- ISO-8601
  until                  TEXT,               -- ISO-8601 end (Stripe cancel_at); NULL = open-ended
  revoked_at             TEXT,               -- ISO-8601 when replaced or removed from the console
  revoked_by             TEXT
);

CREATE INDEX IF NOT EXISTS idx_plan_grants_user ON plan_grants (user_id, granted_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_plan_grants_stripe_sub ON plan_grants (stripe_subscription_id);
