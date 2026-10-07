/**
 * Plans and per-plan feature gates, read from D1.
 *
 * Plans used to be a hardcoded `proPlan(env)`, so adding a tier or changing
 * what a tier includes meant editing code and deploying. @better-auth/stripe
 * accepts `plans` as an async function, so they come from the `plan` table
 * instead and the admin console can edit them.
 *
 * # The free plan is a row
 *
 * It has no `price_id` and is never sold, but it carries the same feature and
 * limit shape as every paid tier. That means gating has ONE code path — you
 * always resolve a plan and ask it a question — instead of a special case that
 * has to be remembered at every call site.
 *
 * # Two schemas per shape, on purpose
 *
 * Stored JSON is parsed with the LENIENT schema: every key falls back to its
 * deny value on its own (`.catch`), so an old row that predates a key, or a
 * hand-edited row with one bad value, denies that one feature rather than
 * throwing or granting anything. Unknown keys are dropped.
 *
 * Admin writes go through the STRICT schema: unknown keys are rejected so a
 * typo in the console cannot silently create a flag nothing reads, and wrong
 * types are a 400 rather than a quiet deny at runtime.
 */

import { z } from "zod";
import type { StripePlan } from "@better-auth/stripe";
import type { EntitlementTier } from "../types";

/**
 * Everything gateable. Adding a key here is the whole job of adding a gate.
 *
 *   webCapture      Capture a web page by URL from the desktop app.
 *   imageUpload     Upload still images (screenshots) rather than only recordings.
 *   cloudShare      Upload at all, and get a share link.
 *   comments        Viewers can leave timestamped comments on a shared video.
 *   removeWatermark Export without the CaptureCat watermark.
 *   customDomain    Serve share pages from the user's own domain (CNAME).
 *   aiSummaries     Server-side Gemini titles/summaries/chapters for shares.
 *   screenshotApi   /api/screenshot/take — the paid screenshot-rendering API.
 *   teams           Team library: share videos into an organization.
 *   sso             Enterprise SSO (OIDC/SAML) — register an identity provider.
 *   customStorage   Share videos stored in the user's own S3-compatible bucket.
 */
export const FEATURE_KEYS = [
  "webCapture",
  "imageUpload",
  "cloudShare",
  "comments",
  "removeWatermark",
  "customDomain",
  "aiSummaries",
  "screenshotApi",
  "teams",
  "sso",
  "customStorage",
] as const;
export type FeatureKey = (typeof FEATURE_KEYS)[number];

/**
 * Every enforced cap. `routes/upload.ts` (via `lib/upload-policy.ts`) and
 * `routes/screenshot.ts` are the enforcement points; nothing else may carry a
 * copy of these numbers.
 *
 *   maxTotalStorageBytes    Sum of every ready video version the user owns.
 *                           0 = the plan permits no uploads.
 *   maxFileSizeBytes        Per upload. 0 = no uploads.
 *   maxDurationSeconds      Per upload. 0 = no duration cap (a zero-second
 *                           cap is meaningless, and storage already gates).
 *   maxUploadsPerDay        New shares per UTC day. 0 = no uploads.
 *   maxScreenshotsPerMonth  Screenshot API renders per UTC calendar month;
 *                           0 = none.
 *   maxHistoryDays          Cloud-project history: unnamed versions are kept
 *                           this many days (lib/project-history.ts). 0 = no
 *                           cloud history (only the current version).
 *   maxNamedVersions        Named versions per project, exempt from the day
 *                           window. 0 = naming is not included.
 */
export const LIMIT_KEYS = [
  "maxTotalStorageBytes",
  "maxFileSizeBytes",
  "maxDurationSeconds",
  "maxUploadsPerDay",
  "maxScreenshotsPerMonth",
  "maxHistoryDays",
  "maxNamedVersions",
] as const;
export type LimitKey = (typeof LIMIT_KEYS)[number];

function shapeOf<K extends string, S extends z.ZodType>(keys: readonly K[], schema: S): Record<K, S> {
  return Object.fromEntries(keys.map((k) => [k, schema])) as Record<K, S>;
}

// --- Lenient (stored rows) -------------------------------------------------

/** Deny by default, per key: missing, null, "true", 1 — all read as false. */
export const PlanFeaturesSchema = z.object(shapeOf(FEATURE_KEYS, z.boolean().catch(false)));
export type PlanFeatures = z.infer<typeof PlanFeaturesSchema>;

/** Zero by default, per key: missing, negative, fractional, or non-numeric
 *  values all read as 0, which every consumer treats as "none". */
export const PlanLimitsSchema = z.object(shapeOf(LIMIT_KEYS, z.int().min(0).catch(0)));
export type PlanLimits = z.infer<typeof PlanLimitsSchema>;

// --- Strict (admin writes) --------------------------------------------------

export const PlanFeaturesInputSchema = z.strictObject(
  shapeOf(FEATURE_KEYS, z.boolean().default(false)),
);
export const PlanLimitsInputSchema = z.strictObject(
  shapeOf(LIMIT_KEYS, z.int().min(0).default(0)),
);

/** Parse a stored JSON blob. Never throws: garbage becomes the all-deny shape. */
export function parseStoredFeatures(raw: unknown): PlanFeatures {
  return PlanFeaturesSchema.parse(parseObject(raw));
}
export function parseStoredLimits(raw: unknown): PlanLimits {
  return PlanLimitsSchema.parse(parseObject(raw));
}

function parseObject(raw: unknown): Record<string, unknown> {
  let value: unknown = raw;
  if (typeof raw === "string") {
    try {
      value = JSON.parse(raw);
    } catch {
      return {};
    }
  }
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

export interface PlanRecord {
  id: string;
  name: string;
  displayName: string;
  description: string | null;
  priceId: string | null;
  annualPriceId: string | null;
  trialDays: number;
  features: PlanFeatures;
  limits: PlanLimits;
  sortOrder: number;
  isActive: boolean;
  /** Display amounts, written by the Stripe sync and the price webhooks
   *  (lib/stripe-catalog.ts); null = never synced. */
  monthlyAmountCents: number | null;
  annualAmountCents: number | null;
  currency: string;
  /** The plan's ONE Stripe product (`prod_…`), set by the sync; null = never
   *  synced. Product webhooks are matched on it. */
  stripeProductId: string | null;
  /** "Most popular": the plan the site features. Display only. */
  popular: boolean;
  /** A time-limited sale (lib/plan-sale.ts). Prices in minor units, times
   *  ISO-8601; all null = no sale. Live only while its coupon exists. */
  saleLabel: string | null;
  salePriceMonthlyCents: number | null;
  salePriceAnnualCents: number | null;
  saleStartsAt: string | null;
  saleEndsAt: string | null;
  /** null = the discount lasts as long as the subscriber stays; N = N months. */
  saleDurationMonths: number | null;
  stripeSaleCouponId: string | null;
  stripeSaleAnnualCouponId: string | null;
}

interface PlanRow {
  id: string;
  name: string;
  display_name: string;
  description: string | null;
  price_id: string | null;
  annual_price_id: string | null;
  trial_days: number;
  features: string;
  limits: string;
  sort_order: number;
  is_active: number;
  monthly_amount_cents?: number | null;
  annual_amount_cents?: number | null;
  currency?: string | null;
  stripe_product_id?: string | null;
  popular?: number | null;
  sale_label?: string | null;
  sale_price_monthly_cents?: number | null;
  sale_price_annual_cents?: number | null;
  sale_starts_at?: string | null;
  sale_ends_at?: string | null;
  sale_duration_months?: number | null;
  stripe_sale_coupon_id?: string | null;
  stripe_sale_annual_coupon_id?: string | null;
}

function toRecord(row: PlanRow): PlanRecord {
  return {
    id: row.id,
    name: row.name,
    displayName: row.display_name,
    description: row.description,
    priceId: row.price_id,
    annualPriceId: row.annual_price_id,
    trialDays: row.trial_days,
    features: parseStoredFeatures(row.features),
    limits: parseStoredLimits(row.limits),
    sortOrder: row.sort_order,
    isActive: row.is_active === 1,
    monthlyAmountCents: row.monthly_amount_cents ?? null,
    annualAmountCents: row.annual_amount_cents ?? null,
    currency: row.currency ?? "usd",
    stripeProductId: row.stripe_product_id ?? null,
    popular: row.popular === 1,
    saleLabel: row.sale_label ?? null,
    salePriceMonthlyCents: row.sale_price_monthly_cents ?? null,
    salePriceAnnualCents: row.sale_price_annual_cents ?? null,
    saleStartsAt: row.sale_starts_at ?? null,
    saleEndsAt: row.sale_ends_at ?? null,
    saleDurationMonths: row.sale_duration_months ?? null,
    stripeSaleCouponId: row.stripe_sale_coupon_id ?? null,
    stripeSaleAnnualCouponId: row.stripe_sale_annual_coupon_id ?? null,
  };
}

export async function listPlans(db: D1Database, activeOnly = true): Promise<PlanRecord[]> {
  const sql = activeOnly
    ? `SELECT * FROM plan WHERE is_active = 1 ORDER BY sort_order, name`
    : `SELECT * FROM plan ORDER BY sort_order, name`;
  const { results } = await db.prepare(sql).all<PlanRow>();
  return (results ?? []).map(toRecord);
}

export async function planByName(db: D1Database, name: string): Promise<PlanRecord | null> {
  const row = await db.prepare(`SELECT * FROM plan WHERE name = ?`).bind(name).first<PlanRow>();
  return row ? toRecord(row) : null;
}

export async function planById(db: D1Database, id: string): Promise<PlanRecord | null> {
  const row = await db.prepare(`SELECT * FROM plan WHERE id = ?`).bind(id).first<PlanRow>();
  return row ? toRecord(row) : null;
}

/**
 * The free plan, or a fully-denying stand-in if the row is missing.
 *
 * Never throws: a lookup failure must not become "everything is allowed". The
 * fallback denies every feature and every limit.
 */
export async function freePlan(db: D1Database): Promise<PlanRecord> {
  const found = await planByName(db, "free").catch(() => null);
  return (
    found ?? {
      id: "plan_free",
      name: "free",
      displayName: "Free",
      description: null,
      priceId: null,
      annualPriceId: null,
      trialDays: 0,
      features: parseStoredFeatures({}),
      limits: parseStoredLimits({}),
      sortOrder: 0,
      isActive: true,
      monthlyAmountCents: null,
      annualAmountCents: null,
      currency: "usd",
      stripeProductId: null,
      popular: false,
      saleLabel: null,
      salePriceMonthlyCents: null,
      salePriceAnnualCents: null,
      saleStartsAt: null,
      saleEndsAt: null,
      saleDurationMonths: null,
      stripeSaleCouponId: null,
      stripeSaleAnnualCouponId: null,
    }
  );
}

/** Billing interval as Stripe names it (`recurring.interval`). */
export type BillingInterval = "month" | "year";

/**
 * The Stripe lookup key that names a plan's price for one interval:
 * `capturecat_pro_monthly`, `capturecat_pro_yearly`. Lookup keys are unique
 * across an account's prices, so this is how a price is FOUND (by the sync,
 * the webhooks and checkout) instead of hard-coding its `price_…` id.
 */
export function lookupKeyFor(plan: string, interval: BillingInterval): string {
  return `capturecat_${plan}_${interval === "month" ? "monthly" : "yearly"}`;
}

/** Inverse of `lookupKeyFor`; null for any key that is not ours. */
export function parseLookupKey(
  key: string | null | undefined,
): { plan: string; interval: BillingInterval } | null {
  const m = key ? /^capturecat_([a-z][a-z0-9_-]{1,31})_(monthly|yearly)$/.exec(key) : null;
  return m ? { plan: m[1], interval: m[2] === "monthly" ? "month" : "year" } : null;
}

/** Resolves lookup keys to ACTIVE price ids (a key with no price is absent
 *  from the map). Supplied by lib/stripe-catalog.ts; never throws. */
export type LookupKeyResolver = (keys: string[]) => Promise<Map<string, string>>;

/**
 * Plans in the shape @better-auth/stripe wants, read from the plan TABLE only.
 * No price on this path is hard-coded or read from an env var.
 *
 * Only ACTIVE rows are offered (a plan hidden in the admin console is not for
 * sale, whatever Stripe holds), and never the free plan. A row's price is the
 * id the Stripe sync stored; a row without one falls back to its lookup key in
 * Stripe (`resolveKeys`), which covers a price keyed in the Stripe Dashboard
 * whose webhook has not landed yet. A row with no price either way is
 * dropped: the plugin would happily accept it and then create a checkout
 * session against an empty price, which fails inside Stripe with a message
 * that points nowhere near the cause.
 */
export async function stripePlansFromDB(
  env: { DB: D1Database },
  resolveKeys?: LookupKeyResolver,
): Promise<StripePlan[]> {
  const plans = (await listPlans(env.DB, true)).filter((p) => p.name !== "free");

  const missing: string[] = [];
  for (const p of plans) {
    if (!p.priceId?.trim()) missing.push(lookupKeyFor(p.name, "month"));
    if (!p.annualPriceId?.trim()) missing.push(lookupKeyFor(p.name, "year"));
  }
  const keyed = missing.length > 0 && resolveKeys ? await resolveKeys(missing) : new Map<string, string>();

  const out: StripePlan[] = [];
  for (const p of plans) {
    const priceId = p.priceId?.trim() || keyed.get(lookupKeyFor(p.name, "month"));
    if (!priceId) continue;
    out.push({
      name: p.name,
      priceId,
      annualDiscountPriceId: p.annualPriceId?.trim() || keyed.get(lookupKeyFor(p.name, "year")) || undefined,
      limits: p.limits as unknown as Record<string, number>,
      ...(p.trialDays > 0 ? { freeTrial: { days: p.trialDays } } : {}),
    });
  }
  return out;
}

/**
 * The ONE resolution from a server-resolved entitlement to the plan row that
 * governs it. Every feature or limit check goes through here.
 *
 *   paid + planName  → that plan, ACTIVE OR HIDDEN. Hiding a plan in the
 *                      admin console only stops NEW checkouts (the plugin is
 *                      only ever offered active rows — see
 *                      `stripePlansFromDB`); a customer already paying for it
 *                      keeps what they paid for until the subscription ends,
 *                      which is when `tier` stops being "paid". A plan that
 *                      no longer EXISTS (deleted, or renamed) must not
 *                      silently become the most generous tier — it becomes
 *                      the least, and is logged, so the mistake is visible
 *                      in the console instead of in the bill.
 *   paid, no name    → pro. Only reachable when the subscription-plan
 *                      lookup itself failed (requireEntitlement fails soft
 *                      there), so a D1 blip costs a paying user nothing.
 *   tester           → pro
 *   anything else    → free
 *
 * Never throws: a D1 blip degrades to free, which denies everything — the
 * same fail-closed posture as `freePlan`.
 */
export async function planForEntitlement(
  db: D1Database,
  entitlement: { tier: EntitlementTier; planName?: string | null },
): Promise<PlanRecord> {
  const { tier, planName } = entitlement;
  if (tier === "paid" && planName) {
    const plan = await planByName(db, planName.toLowerCase()).catch(() => null);
    if (plan) return plan;
    console.error(`plans: subscription names plan "${planName}" which does not exist — denying`);
    return freePlan(db);
  }
  if (tier === "paid" || tier === "tester") {
    const pro = await planByName(db, "pro").catch(() => null);
    if (pro) return pro;
  }
  return freePlan(db);
}

/** The full plan record for a tier when the subscribed plan name is not at
 *  hand (session-less callers such as the screenshot API's key auth). */
export async function planForTier(db: D1Database, tier: EntitlementTier): Promise<PlanRecord> {
  return planForEntitlement(db, { tier });
}

/** The feature set for a resolved entitlement. */
export async function featuresForTier(
  db: D1Database,
  tier: EntitlementTier,
  planName?: string | null,
): Promise<PlanFeatures> {
  return (await planForEntitlement(db, { tier, planName })).features;
}
