-- Reverts 0006. @better-auth/stripe owns the `subscription` table and writes it
-- only from its webhook, so a locally-granted `user.subscribed` flag was a
-- second source of paid truth that Stripe would never agree with.
--
-- Comps are a Stripe operation instead: every user already has a
-- stripeCustomerId (createCustomerOnSignUp), so start a `freeTrial` on the plan
-- or create the subscription with a 100%-off coupon. The webhook writes the
-- row and resolveTier() reports "paid" with no bespoke code — `trialing` is
-- already in PAID_SUBSCRIPTION_STATUSES.
ALTER TABLE user DROP COLUMN subscribed;
