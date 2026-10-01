/**
 * Admin plan editor — SAVE IS SYNC.
 *
 * Creating or saving a plan provisions Stripe in the same request
 * (lib/stripe-catalog.ts `provisionPlan`): one product per plan, a price per
 * interval found by lookup key, a sale coupon per interval. Stripe goes FIRST
 * and only additively; the plan row is written after it succeeds; then what
 * was replaced is archived. If the row cannot be written, everything this
 * request created in Stripe is undone — nothing is ever left selling that D1
 * does not know about.
 *
 *   GET  /admin/plans                    every plan (+ whether Stripe is set up)
 *   POST /admin/plans                    create (and provision)
 *   PUT  /admin/plans/:id                edit (and provision); partial body,
 *                                        merged over the row
 *   POST /admin/plans/:id/active         hide from sale / publish — no Stripe
 *   POST /admin/plans/:id/popular        "Most popular" — no Stripe
 *   POST /admin/plans/:id/stripe-sync    re-sync without edits (first adoption)
 *   POST /admin/plans/stripe-sync        every plan except free
 *
 * `name` is NOT editable. @better-auth/stripe stores it on every
 * `subscription` row, so renaming a plan would orphan existing subscribers
 * from the tier they pay for. Create a new plan instead.
 *
 * Price ids are not accepted from the console at all: the sync and the
 * catalog webhooks own them, and a stale form re-sending one would put back a
 * price a webhook had just replaced. Unknown keys (an old console's
 * `priceId`) are dropped.
 *
 * Registered onto `adminRoutes` (routes/admin.ts) so its admin guard applies.
 */

import type { Hono } from "hono";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { createStripeClient } from "../lib/stripe";
import {
  listPlans,
  planById,
  PlanFeaturesInputSchema,
  PlanLimitsInputSchema,
  type PlanRecord,
} from "../lib/plans";
import { saleProblem } from "../lib/plan-sale";
import {
  provisionPlan,
  syncAllPlansToStripe,
  syncPlanToStripe,
  SyncRefusedError,
  type DesiredPlan,
  type PlanSyncSummary,
  type Provisioned,
} from "../lib/stripe-catalog";
import { parseJsonBody } from "../lib/validate";

type App = Hono<{ Bindings: Env; Variables: Variables }>;

/** Trimmed; blank → null so the DB never stores "". */
const optionalText = (max: number) =>
  z
    .string()
    .max(max)
    .nullish()
    .transform((v) => v?.trim() || null);

const cents = z.int().min(1).max(100_000_000);
const isoTime = z.iso.datetime({ offset: true });

/**
 * Every field optional, no defaults: a PUT only carries what the console
 * sent, merged over the stored row. Amounts in minor units.
 */
const PlanFieldsSchema = z.object({
  displayName: z.string().trim().min(1, { error: "displayName is required" }).max(80),
  description: optionalText(500),
  /** null = not sold on this interval (archives its price). */
  monthlyCents: cents.nullable(),
  annualCents: cents.nullable(),
  currency: z
    .string()
    .trim()
    .toLowerCase()
    .regex(/^[a-z]{3}$/, { error: "currency must be a 3-letter ISO code" }),
  trialDays: z.int().min(0).max(365),
  // Objects, not strings: accepting pre-serialised JSON here would let a typo
  // write an unparseable blob that silently denies every feature at runtime.
  // STRICT shapes: an unknown key is a 400, never a flag nothing reads.
  features: PlanFeaturesInputSchema,
  limits: PlanLimitsInputSchema,
  sortOrder: z.int().min(0).max(10_000),
  isActive: z.boolean(),
  popular: z.boolean(),
  saleLabel: optionalText(40),
  salePriceMonthlyCents: z.int().min(0).max(100_000_000).nullable(),
  salePriceAnnualCents: z.int().min(0).max(100_000_000).nullable(),
  saleStartsAt: isoTime.nullable(),
  saleEndsAt: isoTime.nullable(),
  /** null = for as long as they stay subscribed. */
  saleDurationMonths: z.int().min(1).max(36).nullable(),
});
const PlanPatchSchema = PlanFieldsSchema.partial();
type PlanFields = z.output<typeof PlanFieldsSchema>;

const PlanCreateSchema = PlanPatchSchema.extend({
  // The name becomes the identity @better-auth/stripe writes onto every
  // subscription row, so keep it to a slug rather than free text.
  name: z
    .string({ error: "name is required" })
    .trim()
    .toLowerCase()
    .regex(/^[a-z][a-z0-9_-]{1,31}$/, {
      error: "name must be a lowercase slug, 2-32 chars, starting with a letter",
    }),
  displayName: z.string({ error: "displayName is required" }).trim().min(1, { error: "displayName is required" }).max(80),
});

const PRICING_KEYS = [
  "monthlyCents",
  "annualCents",
  "currency",
  "saleLabel",
  "salePriceMonthlyCents",
  "salePriceAnnualCents",
  "saleStartsAt",
  "saleEndsAt",
  "saleDurationMonths",
] as const;

/** A stored row in the editor's shape, so a partial edit merges over it. */
function rowFields(p: PlanRecord): PlanFields {
  return {
    displayName: p.displayName,
    description: p.description,
    monthlyCents: p.monthlyAmountCents,
    annualCents: p.annualAmountCents,
    currency: p.currency,
    trialDays: p.trialDays,
    features: p.features,
    limits: p.limits,
    sortOrder: p.sortOrder,
    isActive: p.isActive,
    popular: p.popular,
    saleLabel: p.saleLabel,
    salePriceMonthlyCents: p.salePriceMonthlyCents,
    salePriceAnnualCents: p.salePriceAnnualCents,
    saleStartsAt: p.saleStartsAt,
    saleEndsAt: p.saleEndsAt,
    saleDurationMonths: p.saleDurationMonths,
  };
}

/** ISO in, ISO (UTC, ms) out — one spelling in the table. */
const normIso = (v: string | null) => (v ? new Date(v).toISOString() : null);

function desiredOf(name: string, f: PlanFields): DesiredPlan {
  return {
    name,
    displayName: f.displayName,
    description: f.description,
    monthlyCents: f.monthlyCents,
    annualCents: f.annualCents,
    currency: f.currency,
    trialDays: f.trialDays,
    sale: {
      label: f.saleLabel,
      monthlyCents: f.salePriceMonthlyCents,
      annualCents: f.salePriceAnnualCents,
      startsAt: normIso(f.saleStartsAt),
      endsAt: normIso(f.saleEndsAt),
      durationMonths: f.saleDurationMonths,
    },
  };
}

function legacyPriceEnv(env: Env) {
  return {
    STRIPE_PRO_PRICE_ID: env.STRIPE_PRO_PRICE_ID,
    STRIPE_PRO_ANNUAL_PRICE_ID: env.STRIPE_PRO_ANNUAL_PRICE_ID,
    STRIPE_PRO_TRIAL_DAYS: env.STRIPE_PRO_TRIAL_DAYS,
  };
}

/** D1 refused the row after Stripe succeeded; Stripe has been rolled back. */
class PlanWriteError extends Error {}

function errorResponse(err: unknown): { body: { error: string }; status: 400 | 404 | 409 | 500 | 502 | 503 } {
  if (err instanceof SyncRefusedError) return { body: { error: err.message }, status: err.status };
  if (err instanceof PlanWriteError) {
    console.error("plan save: D1 write failed after Stripe; Stripe rolled back", err);
    return { body: { error: err.message }, status: 500 };
  }
  // A Stripe error message is the useful part ("No such price", "currency
  // mismatch"); it carries no secret.
  console.error("plan save / stripe sync failed", err);
  return { body: { error: `Stripe sync failed: ${err instanceof Error ? err.message : String(err)}` }, status: 502 };
}

/**
 * Provision when Stripe is configured and the plan is sellable; refuse a
 * pricing change Stripe cannot carry out. Free never provisions.
 */
async function provisionFor(
  env: Env,
  current: PlanRecord | null,
  name: string,
  fields: PlanFields,
  pricingChanged: boolean,
): Promise<Provisioned | null> {
  if (name === "free") {
    if (pricingChanged) throw new SyncRefusedError("The free plan is never sold");
    return null;
  }
  if (!env.STRIPE_SECRET_KEY) {
    if (pricingChanged) throw new SyncRefusedError("Stripe is not configured (STRIPE_SECRET_KEY), so prices cannot change", 503);
    const problem = saleProblem({ ...fields });
    if (problem) throw new SyncRefusedError(problem);
    return null;
  }
  return provisionPlan(createStripeClient(env), env.DB, current, desiredOf(name, fields), legacyPriceEnv(env));
}

/** The editable, non-Stripe columns, in one statement. */
function fieldsUpdate(db: D1Database, id: string, f: PlanFields, p: Provisioned | null): D1PreparedStatement {
  const c = p?.columns;
  return db
    .prepare(
      `UPDATE plan SET display_name = ?, description = ?, trial_days = ?, features = ?, limits = ?,
                       sort_order = ?, is_active = ?, popular = ?,
                       sale_label = ?, sale_price_monthly_cents = ?, sale_price_annual_cents = ?,
                       sale_starts_at = ?, sale_ends_at = ?, sale_duration_months = ?,
                       stripe_product_id = COALESCE(?, stripe_product_id),
                       price_id = CASE WHEN ? THEN ? ELSE price_id END,
                       annual_price_id = CASE WHEN ? THEN ? ELSE annual_price_id END,
                       monthly_amount_cents = CASE WHEN ? THEN ? ELSE monthly_amount_cents END,
                       annual_amount_cents = CASE WHEN ? THEN ? ELSE annual_amount_cents END,
                       currency = ?,
                       stripe_sale_coupon_id = CASE WHEN ? THEN ? ELSE stripe_sale_coupon_id END,
                       stripe_sale_annual_coupon_id = CASE WHEN ? THEN ? ELSE stripe_sale_annual_coupon_id END,
                       updated_at = datetime('now')
        WHERE id = ?`,
    )
    .bind(
      f.displayName,
      f.description,
      c?.trial_days ?? f.trialDays,
      JSON.stringify(f.features),
      JSON.stringify(f.limits),
      f.sortOrder,
      f.isActive ? 1 : 0,
      f.popular ? 1 : 0,
      f.saleLabel,
      f.salePriceMonthlyCents,
      f.salePriceAnnualCents,
      normIso(f.saleStartsAt),
      normIso(f.saleEndsAt),
      f.saleDurationMonths,
      c?.stripe_product_id ?? null,
      c ? 1 : 0, c?.price_id ?? null,
      c ? 1 : 0, c?.annual_price_id ?? null,
      c ? 1 : 0, c?.monthly_amount_cents ?? null,
      c ? 1 : 0, c?.annual_amount_cents ?? null,
      c?.currency ?? f.currency,
      c ? 1 : 0, c?.stripe_sale_coupon_id ?? null,
      c ? 1 : 0, c?.stripe_sale_annual_coupon_id ?? null,
      id,
    );
}

/** Write D1 after Stripe succeeded; undo Stripe if D1 fails; then archive
 *  what was replaced. */
async function commit(
  db: D1Database,
  statements: D1PreparedStatement[],
  provisioned: Provisioned | null,
): Promise<PlanSyncSummary | null> {
  try {
    await db.batch(statements);
  } catch (err) {
    await provisioned?.rollback();
    const why = err instanceof Error ? err.message : String(err);
    throw new PlanWriteError(
      `Could not save the plan (${why})${provisioned ? "; the Stripe changes were undone" : ""}`,
    );
  }
  await provisioned?.finish();
  return provisioned?.summary ?? null;
}

export function registerPlanAdminRoutes(app: App): void {
  /**
   * Unlike the public /api/plans this returns the feature and limit maps so
   * the console can edit them, and it does not filter to sellable rows: the
   * free plan has no price and is still very much editable.
   */
  app.get("/admin/plans", async (c) => {
    const plans = await listPlans(c.env.DB, false);
    return c.json({ plans, stripeConfigured: !!c.env.STRIPE_SECRET_KEY });
  });

  app.post("/admin/plans", async (c) => {
    const parsed = await parseJsonBody(c.req, PlanCreateSchema, { emptyOnInvalidJson: true });
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const { name, ...patch } = parsed.data;

    const exists = await c.env.DB.prepare(`SELECT 1 FROM plan WHERE name = ?`).bind(name).first();
    if (exists) return c.json({ error: `A plan named "${name}" already exists` }, 409);

    // Created INACTIVE unless the console says otherwise: a new tier should
    // not appear on the pricing page the moment it is created.
    const fields: PlanFields = {
      displayName: patch.displayName,
      description: patch.description ?? null,
      monthlyCents: patch.monthlyCents ?? null,
      annualCents: patch.annualCents ?? null,
      currency: patch.currency ?? "usd",
      trialDays: patch.trialDays ?? 0,
      features: patch.features ?? PlanFeaturesInputSchema.parse({}),
      limits: patch.limits ?? PlanLimitsInputSchema.parse({}),
      sortOrder: patch.sortOrder ?? 100,
      isActive: patch.isActive ?? false,
      popular: patch.popular ?? false,
      saleLabel: patch.saleLabel ?? null,
      salePriceMonthlyCents: patch.salePriceMonthlyCents ?? null,
      salePriceAnnualCents: patch.salePriceAnnualCents ?? null,
      saleStartsAt: patch.saleStartsAt ?? null,
      saleEndsAt: patch.saleEndsAt ?? null,
      saleDurationMonths: patch.saleDurationMonths ?? null,
    };
    const pricing = fields.monthlyCents != null || fields.annualCents != null || fields.salePriceMonthlyCents != null || fields.salePriceAnnualCents != null;

    const id = `plan_${crypto.randomUUID().slice(0, 8)}`;
    try {
      const provisioned = await provisionFor(c.env, null, name, fields, pricing);
      const insert = c.env.DB.prepare(
        `INSERT INTO plan (id, name, display_name, features, limits, sort_order, is_active) VALUES (?, ?, ?, '{}', '{}', 100, 0)`,
      ).bind(id, name, fields.displayName);
      const statements = [
        ...(fields.popular ? [c.env.DB.prepare(`UPDATE plan SET popular = 0 WHERE popular = 1`)] : []),
        insert,
        fieldsUpdate(c.env.DB, id, fields, provisioned),
      ];
      const summary = await commit(c.env.DB, statements, provisioned);
      if (summary) summary.planId = id;
      return c.json({ plan: await planById(c.env.DB, id), summary }, 201);
    } catch (err) {
      const { body, status } = errorResponse(err);
      return c.json(body, status);
    }
  });

  app.put("/admin/plans/:id", async (c) => {
    const current = await planById(c.env.DB, c.req.param("id"));
    if (!current) return c.json({ error: "Plan not found" }, 404);
    const parsed = await parseJsonBody(c.req, PlanPatchSchema, { emptyOnInvalidJson: true });
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const patch = parsed.data;

    const before = rowFields(current);
    const fields: PlanFields = { ...before };
    for (const [k, v] of Object.entries(patch)) {
      if (v !== undefined) (fields as Record<string, unknown>)[k] = v;
    }
    // The free plan is the fallback tier every unpaid user resolves to —
    // hiding it would leave signed-in users with no feature set at all.
    if (current.name === "free" && !fields.isActive) {
      return c.json({ error: "The free plan is the fallback tier and cannot be hidden" }, 400);
    }
    const pricingChanged = PRICING_KEYS.some((k) => {
      const a = k === "saleStartsAt" || k === "saleEndsAt" ? normIso(fields[k]) : fields[k];
      const b = k === "saleStartsAt" || k === "saleEndsAt" ? normIso(before[k]) : before[k];
      return a !== b;
    });

    try {
      const provisioned = await provisionFor(c.env, current, current.name, fields, pricingChanged);
      const statements = [
        ...(fields.popular && !current.popular
          ? [c.env.DB.prepare(`UPDATE plan SET popular = 0 WHERE popular = 1 AND id != ?`).bind(current.id)]
          : []),
        fieldsUpdate(c.env.DB, current.id, fields, provisioned),
      ];
      const summary = await commit(c.env.DB, statements, provisioned);
      return c.json({ plan: await planById(c.env.DB, current.id), summary });
    } catch (err) {
      const { body, status } = errorResponse(err);
      return c.json(body, status);
    }
  });

  /**
   * Hide from sale / publish. Hidden stops NEW checkouts only: existing
   * subscribers keep the plan's features until their subscription ends
   * (lib/plans.ts planForEntitlement). Touches nothing in Stripe, so it works
   * even when Stripe does not.
   */
  app.post("/admin/plans/:id/active", async (c) => {
    const parsed = await parseJsonBody(c.req, z.object({ isActive: z.boolean() }));
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const plan = await planById(c.env.DB, c.req.param("id"));
    if (!plan) return c.json({ error: "Plan not found" }, 404);
    if (plan.name === "free" && !parsed.data.isActive) {
      return c.json({ error: "The free plan is the fallback tier and cannot be hidden" }, 400);
    }
    await c.env.DB.prepare(`UPDATE plan SET is_active = ?, updated_at = datetime('now') WHERE id = ?`)
      .bind(parsed.data.isActive ? 1 : 0, plan.id)
      .run();
    return c.json({ plan: await planById(c.env.DB, plan.id) });
  });

  /** "Most popular" — display only, at most one. Nothing changes in Stripe. */
  app.post("/admin/plans/:id/popular", async (c) => {
    const parsed = await parseJsonBody(c.req, z.object({ popular: z.boolean() }));
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const plan = await planById(c.env.DB, c.req.param("id"));
    if (!plan) return c.json({ error: "Plan not found" }, 404);
    await c.env.DB.batch([
      ...(parsed.data.popular ? [c.env.DB.prepare(`UPDATE plan SET popular = 0 WHERE popular = 1`)] : []),
      c.env.DB.prepare(`UPDATE plan SET popular = ?, updated_at = datetime('now') WHERE id = ?`).bind(
        parsed.data.popular ? 1 : 0,
        plan.id,
      ),
    ]);
    return c.json({ plan: await planById(c.env.DB, plan.id) });
  });

  /**
   * Re-sync without edits: make Stripe match the row as it is. One product,
   * prices by lookup key, so a second click changes nothing (`changed:
   * false`). An amount left out keeps what Stripe charges — the first time,
   * that ADOPTS an un-keyed price (the row's, or Pro's legacy
   * `STRIPE_PRO_PRICE_ID` / `STRIPE_PRO_ANNUAL_PRICE_ID`): keyed in place,
   * nobody moved. Optional `{ monthlyCents, annualCents, currency }` replace
   * that interval's price instead.
   */
  const SyncBodySchema = z.object({
    monthlyCents: cents.nullish(),
    annualCents: cents.nullish(),
    currency: z
      .string()
      .trim()
      .toLowerCase()
      .regex(/^[a-z]{3}$/, { error: "currency must be a 3-letter ISO code" })
      .nullish(),
  });

  app.post("/admin/plans/stripe-sync", async (c) => {
    if (!c.env.STRIPE_SECRET_KEY) return c.json({ error: "STRIPE_SECRET_KEY is not configured" }, 503);
    const results = await syncAllPlansToStripe(createStripeClient(c.env), c.env.DB, legacyPriceEnv(c.env));
    return c.json({ results });
  });

  app.post("/admin/plans/:id/stripe-sync", async (c) => {
    if (!c.env.STRIPE_SECRET_KEY) return c.json({ error: "STRIPE_SECRET_KEY is not configured" }, 503);
    const parsed = await parseJsonBody(c.req, SyncBodySchema, { emptyOnInvalidJson: true });
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    try {
      const summary = await syncPlanToStripe(
        createStripeClient(c.env),
        c.env.DB,
        c.req.param("id"),
        parsed.data,
        legacyPriceEnv(c.env),
      );
      return c.json({ summary });
    } catch (err) {
      const { body, status } = errorResponse(err);
      return c.json(body, status);
    }
  });
}
