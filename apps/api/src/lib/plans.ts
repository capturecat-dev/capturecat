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
 */
export const LIMIT_KEYS = [
  "maxTotalStorageBytes",
  "maxFileSizeBytes",
  "maxDurationSeconds",
  "maxUploadsPerDay",
  "maxScreenshotsPerMonth",
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
  /** Display amounts recorded at Stripe-sync time; null = never synced. */
  monthlyAmountCents: number | null;
  annualAmountCents: number | null;
  currency: string;
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
      features: parseStoredFeatures({}),
      limits: parseStoredLimits({}),
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

/**
 * The ONE resolution from a server-resolved entitlement to the plan row that
 * governs it. Every feature or limit check goes through here.
 *
 *   paid + planName  → that plan if it is still active; otherwise FREE.
 *                      A subscription to a plan the admin has since hidden
 *                      (or renamed) must not silently become the most
 *                      generous tier — it becomes the least, and is logged,
 *                      so the mistake is visible in the console instead of
 *                      in the bill.
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
    if (plan?.isActive) return plan;
    console.error(`plans: subscription names plan "${planName}" which is missing or inactive — denying`);
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
