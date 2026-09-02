/**
 * GET /plans — the public pricing surface.
 *
 * WHY THIS EXISTS. The pricing page hard-coded "$10/month" while the price it
 * actually charges lives in Stripe (STRIPE_PRO_PRICE_ID). Those are two sources
 * of truth for the same number, and the failure is silent: change the price in
 * Stripe and the marketing page keeps advertising the old one until somebody
 * notices. This reads the price FROM Stripe so there is one source.
 *
 * Unauthenticated on purpose — it is the pricing page, and it exposes nothing
 * beyond what that page already displays.
 */

import { Hono } from "hono";
import type Stripe from "stripe";
import type { Env, Variables } from "../types";
import { PRO_PLAN_LIMITS, createStripeClient } from "../lib/stripe";
import { listPlans } from "../lib/plans";

export const planRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

interface PriceView {
  id: string;
  amount: number | null;
  currency: string;
  interval: string | null;
}

async function readPrice(stripe: Stripe, id: string | undefined): Promise<PriceView | null> {
  if (!id?.trim()) return null;
  try {
    const p = await stripe.prices.retrieve(id.trim());
    return {
      id: p.id,
      // Stripe reports minor units; the caller formats.
      amount: p.unit_amount,
      currency: p.currency,
      interval: p.recurring?.interval ?? null,
    };
  } catch (err) {
    console.error("plans: could not read price", id, err instanceof Error ? err.message : err);
    return null;
  }
}

planRoutes.get("/plans", async (c) => {
  if (!c.env.STRIPE_SECRET_KEY) {
    return c.json({ error: "Billing is not configured" }, 503);
  }
  // Reuse the shared factory: it pins `apiVersion` to what the installed SDK
  // ships with and installs the fetch HTTP client Workers needs. A second
  // `new Stripe(...)` here would fork both, and the apiVersion had already
  // drifted when it was written by hand.
  const stripe = createStripeClient(c.env);

  const [monthly, annual] = await Promise.all([
    readPrice(stripe, c.env.STRIPE_PRO_PRICE_ID),
    readPrice(stripe, c.env.STRIPE_PRO_ANNUAL_PRICE_ID),
  ]);

  if (!monthly) {
    return c.json({ error: "No plan is configured" }, 503);
  }

  const trialDays = Number.parseInt(c.env.STRIPE_PRO_TRIAL_DAYS ?? "", 10) || 0;

  // The pricing page's feature bullets and description come from the D1 plan
  // rows (editable in the admin console) — a hardcoded list in the page and
  // this endpoint's price would otherwise be two half-truths about one plan.
  const dbPlans = await listPlans(c.env.DB, true).catch(() => []);
  const proRow = dbPlans.find((p) => p.name === "pro") ?? null;
  const freeRow = dbPlans.find((p) => p.name === "free") ?? null;

  return c.json(
    {
      plan: "pro",
      name: proRow?.displayName ?? "CaptureCat Pro",
      description: proRow?.description ?? null,
      monthly,
      annual,
      trialDays: proRow?.trialDays || trialDays,
      features: proRow?.features ?? null,
      free: freeRow
        ? {
            name: freeRow.displayName,
            description: freeRow.description,
            features: freeRow.features,
            limits: freeRow.limits,
          }
        : null,
      // Informational; routes/upload.ts remains the enforcement point.
      limits: proRow?.limits ?? PRO_PLAN_LIMITS,
    },
    200,
    { "Cache-Control": "public, max-age=300" }
  );
});
