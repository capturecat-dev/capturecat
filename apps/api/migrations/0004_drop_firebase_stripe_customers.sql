-- Retire the bespoke Stripe mapping table.
--
-- `stripe_customers` (uid -> stripe_customer_id/subscription_id/status) was
-- written by the hand-rolled POST /webhooks/stripe route, which is deleted.
-- It is fully replaced by:
--   • @better-auth/stripe's "subscription" table  (referenceId = user.id,
--     status = the raw Stripe status, verbatim)   — created in 0003
--   • "user"."stripeCustomerId"                   — created in 0003
--
-- There are ZERO existing Firebase users, so there is nothing to migrate.
--
-- Depends on 0003_better_auth.sql having created the "subscription" table;
-- apply migrations in order.

DROP INDEX IF EXISTS idx_stripe_customers_customer;
DROP TABLE IF EXISTS stripe_customers;
