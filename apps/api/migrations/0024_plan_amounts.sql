-- Display amounts for plan prices, written by the admin Stripe sync (and the
-- refresh action) so the dashboard/admin can show "$10/mo" without a Stripe
-- round-trip per request. Stripe stays the source of truth for what is
-- CHARGED (the price id); these are what is SHOWN.
ALTER TABLE plan ADD COLUMN monthly_amount_cents INTEGER;
ALTER TABLE plan ADD COLUMN annual_amount_cents INTEGER;
ALTER TABLE plan ADD COLUMN currency TEXT NOT NULL DEFAULT 'usd';
