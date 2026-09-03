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
 */

import type { StripePlan } from "@better-auth/stripe";

/** Everything gateable. Adding a key here is the whole job of adding a gate. */
export interface PlanFeatures {
  /** Capture a web page by URL from the desktop app. */
  webCapture: boolean;
  /** Upload still images (screenshots) rather than only recordings. */
  imageUpload: boolean;
  /** Upload at all, and get a share link. */
  cloudShare: boolean;
  /** Viewers can leave timestamped comments on a shared video. */
  comments: boolean;
  /** Export without the CaptureCat watermark. */
  removeWatermark: boolean;
  /** Serve share pages from the user's own domain (CNAME). */
  customDomain: boolean;
  /** Server-side Gemini titles/summaries/chapters for shares. */
  aiSummaries: boolean;
  /** /api/screenshot/take — the paid screenshot-rendering API. */
  screenshotApi: boolean;
  /** Team library: share videos into an organization. */
  teams: boolean;
  /** Enterprise SSO (OIDC/SAML) — register an identity provider. */
  sso: boolean;
}

export interface PlanLimits {
  maxTotalStorageBytes: number;
  maxFileSizeBytes: number;
  maxDurationSeconds: number;
  maxUploadsPerDay: number;
  /** Screenshot API renders per UTC calendar month; 0 = none. */
  maxScreenshotsPerMonth: number;
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
  /** Display amounts recorded at Stripe-sync time; null = never synced. */
  monthlyAmountCents: number | null;
  annualAmountCents: number | null;
  currency: string;
}

/** Applied when a plan's JSON omits a key, so an older row cannot grant a
 *  feature added later simply by not mentioning it. Deny by default. */
const FEATURE_DEFAULTS: PlanFeatures = {
  webCapture: false,
  imageUpload: false,
  cloudShare: false,
  comments: false,
  removeWatermark: false,
  customDomain: false,
  aiSummaries: false,
  screenshotApi: false,
  teams: false,
  sso: false,
};

const LIMIT_DEFAULTS: PlanLimits = {
  maxTotalStorageBytes: 0,
  maxFileSizeBytes: 0,
  maxDurationSeconds: 0,
  maxUploadsPerDay: 0,
  maxScreenshotsPerMonth: 0,
};

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
}

function parseJSON<T extends object>(raw: string, defaults: T): T {
  try {
    const parsed = JSON.parse(raw) as Partial<T>;
    // Spread defaults FIRST so a missing key denies rather than inherits
    // whatever `undefined` would mean at the call site.
    return { ...defaults, ...parsed };
  } catch {
    return { ...defaults };
  }
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
    features: parseJSON(row.features, FEATURE_DEFAULTS),
    limits: parseJSON(row.limits, LIMIT_DEFAULTS),
    sortOrder: row.sort_order,
    isActive: row.is_active === 1,
    monthlyAmountCents: row.monthly_amount_cents ?? null,
    annualAmountCents: row.annual_amount_cents ?? null,
    currency: row.currency ?? "usd",
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
      features: { ...FEATURE_DEFAULTS },
      limits: { ...LIMIT_DEFAULTS },
      sortOrder: 0,
      isActive: true,
      monthlyAmountCents: null,
      annualAmountCents: null,
      currency: "usd",
    }
  );
}

/**
 * Plans in the shape @better-auth/stripe wants.
 *
 * Rows with no `price_id` are dropped: the plugin would happily accept one and
 * then create a checkout session against an empty price, which fails inside
 * Stripe with a message that points nowhere near the cause. The free plan is
 * exactly such a row, and is not something to sell anyway.
 */
export async function stripePlansFromDB(env: { DB: D1Database }): Promise<StripePlan[]> {
  const plans = await listPlans(env.DB, true);
  return plans
    .filter((p) => p.priceId && p.priceId.trim().length > 0)
    .map((p) => ({
      name: p.name,
      priceId: p.priceId!.trim(),
      annualDiscountPriceId: p.annualPriceId?.trim() || undefined,
      limits: p.limits as unknown as Record<string, number>,
      ...(p.trialDays > 0 ? { freeTrial: { days: p.trialDays } } : {}),
    }));
}

/** The full plan record for a resolved entitlement tier — paid and tester
 *  users get the pro row, everyone else the free row. Use when both features
 *  AND limits are needed (e.g. the screenshot API gate + monthly cap) so one
 *  lookup serves both. */
export async function planForTier(
  db: D1Database,
  tier: "free" | "tester" | "paid"
): Promise<PlanRecord> {
  if (tier === "paid" || tier === "tester") {
    const pro = await planByName(db, "pro").catch(() => null);
    if (pro) return pro;
  }
  return freePlan(db);
}

/** The feature set for a resolved entitlement tier — paid and tester users
 *  get the pro plan's flags, everyone else the free row's. */
export async function featuresForTier(
  db: D1Database,
  tier: "free" | "tester" | "paid",
  /** The subscribed plan's name (subscription.plan) — decides WHICH paid
   *  plan's features apply. Without it, paid falls back to pro, which is
   *  right for every pre-Business subscriber. */
  planName?: string | null
): Promise<PlanFeatures> {
  if (tier === "paid" && planName) {
    const plan = await planByName(db, planName.toLowerCase());
    if (plan?.isActive) return plan.features;
  }
  if (tier === "paid" || tier === "tester") {
    const pro = await planByName(db, "pro");
    if (pro) return pro.features;
  }
  return (await freePlan(db)).features;
}
