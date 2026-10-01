/**
 * GET /plans — the public pricing surface.
 *
 * WHY THIS EXISTS. The pricing page used to hard-code "$10/month" while the
 * price actually charged lived in Stripe. Those are two sources of truth for
 * the same number, and the failure is silent: change the price in Stripe and
 * the marketing page keeps advertising the old one until somebody notices.
 * This reads the price FROM Stripe so there is one source.
 *
 * WHICH price: exactly the one checkout sells — the same `stripePlansFromDB`
 * resolution the Better Auth Stripe plugin is given (the plan row's synced
 * price, else its lookup key in Stripe). There is no env-var price here any
 * more; a deployment whose plans were never synced reports "No plan is
 * configured" rather than advertising something checkout would not sell.
 *
 * Unauthenticated on purpose — it is the pricing page, and it exposes nothing
 * beyond what that page already displays.
 */

import { Hono } from "hono";
import type Stripe from "stripe";
import type { Env, Variables } from "../types";
import { createStripeClient } from "../lib/stripe";
import { resolveLookupKeys } from "../lib/stripe-catalog";
import { listPlans, parseStoredLimits, stripePlansFromDB } from "../lib/plans";
import { currentPrices, nextSaleBoundary } from "../lib/plan-sale";

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

  // The pricing page's feature bullets and description come from the D1 plan
  // rows (editable in the admin console) — a hardcoded list in the page and
  // this endpoint's price would otherwise be two half-truths about one plan.
  const rows = await listPlans(c.env.DB, false);
  const proRow = rows.find((p) => p.name === "pro") ?? null;
  const freeRow = rows.find((p) => p.name === "free" && p.isActive) ?? null;

  // Hidden in the admin console = deliberately not for sale right now. Say
  // so explicitly instead of 503ing, so the dashboard and pricing page can
  // hide their upgrade CTAs rather than render a button that can't work.
  if (proRow && !proRow.isActive) {
    return c.json({ available: false });
  }

  const sellable = await stripePlansFromDB(c.env, (keys) => resolveLookupKeys(stripe, keys));
  const pro = sellable.find((p) => p.name === "pro");
  const [monthly, annual] = await Promise.all([
    readPrice(stripe, pro?.priceId),
    readPrice(stripe, pro?.annualDiscountPriceId),
  ]);

  if (!monthly) {
    return c.json({ error: "No plan is configured" }, 503);
  }

  // A sale (lib/plan-sale.ts): while its window is open, `amount` is what
  // checkout charges (the coupon is applied there by the same rule) and
  // `regularAmount` is the price to strike through. The same answer checkout
  // uses, so the page cannot advertise a price checkout would not charge.
  const now = Date.now();
  const current = proRow ? currentPrices(proRow, now) : null;
  const onSale = (view: PriceView | null, regular: number | null | undefined, sale: number | null | undefined) =>
    view && regular != null && sale != null ? { ...view, amount: sale, regularAmount: view.amount } : view;
  const monthlyNow = onSale(monthly, current?.regularMonthly, current?.monthly);
  const annualNow = onSale(annual, current?.regularAnnual, current?.annual);
  // Never cache past the moment a sale starts or ends.
  const boundary = proRow ? nextSaleBoundary(proRow, now) : null;
  const maxAge = boundary === null ? 300 : Math.max(0, Math.min(300, Math.floor((boundary - now) / 1000)));

  return c.json(
    {
      plan: "pro",
      name: proRow?.displayName ?? "CaptureCat Pro",
      description: proRow?.description ?? null,
      monthly: monthlyNow,
      annual: annualNow,
      sale:
        current?.onSale && proRow
          ? {
              label: proRow.saleLabel ?? "Sale price",
              endsAt: proRow.saleEndsAt,
              // null = the discount lasts as long as they stay subscribed.
              durationMonths: proRow.saleDurationMonths,
            }
          : null,
      popular: proRow?.popular ?? false,
      // The same column checkout reads the trial from.
      trialDays: proRow?.trialDays ?? 0,
      features: proRow?.features ?? null,
      free: freeRow
        ? {
            name: freeRow.displayName,
            description: freeRow.description,
            features: freeRow.features,
            limits: freeRow.limits,
          }
        : null,
      // The same row lib/upload-policy.ts enforces from. No row = no caps.
      limits: proRow?.limits ?? parseStoredLimits({}),
    },
    200,
    { "Cache-Control": `public, max-age=${maxAge}` }
  );
});
