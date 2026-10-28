/**
 * Admin: assign a plan to a user (the console's "Assign plan").
 *
 *   GET  /admin/users/:id/plan   what the user is on, where it comes from,
 *                                and the plans that can be assigned
 *   POST /admin/users/:id/plan   { plan, until }  assign (or "free" = remove)
 *
 * An assigned plan is a REAL Stripe subscription on the plan's monthly price
 * with a 100%-off, forever "complimentary" coupon — the comp route 0007 chose
 * instead of a local paid flag. `subscription` stays the one source of paid
 * truth, so resolveTier() and every feature gate treat it exactly like a plan
 * the user bought, and the plugin's webhooks keep it current (renewals move
 * periodEnd; `until` is Stripe's cancel_at, so it simply ends).
 *
 * The route writes the `subscription` row itself, with the plugin's
 * `subscriptionId` metadata on the Stripe object: the plugin's
 * customer.subscription.created handler then finds the row and skips (no
 * duplicate), and the change is live on the next request whichever webhook
 * events the Stripe endpoint is subscribed to.
 *
 * Never touches what a customer PAYS for: a live subscription that is not one
 * of our grants is a 409 — change that in Stripe, where the money is.
 * Replacing or removing a grant cancels its Stripe subscription at once.
 * `plan_grants` (0032) records who granted what, when, until when.
 *
 * Registered onto `adminRoutes` (routes/admin.ts) so its admin guard applies.
 */
import type { Hono } from "hono";
import type Stripe from "stripe";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { createStripeClient, PAID_SUBSCRIPTION_STATUSES, stripeCustomerIsGone } from "../lib/stripe";
import { listPlans, lookupKeyFor, planByName, type PlanRecord } from "../lib/plans";
import { resolveLookupKeys } from "../lib/stripe-catalog";
import { purgePlanCache } from "../lib/entitlement";
import { generateId } from "../lib/id";
import { parseJsonBody } from "../lib/validate";

type App = Hono<{ Bindings: Env; Variables: Variables }>;

/** One coupon for every grant: 100% off, forever. Fixed id, so it is
 *  created once per Stripe account and found by id after that. */
export const COMP_COUPON_ID = "capturecat_complimentary";

const AssignSchema = z.strictObject({
  plan: z.string().trim().toLowerCase().min(1).max(32),
  /** End of the grant (YYYY-MM-DD or ISO); null/absent = open-ended. */
  until: z.string().trim().min(1).max(40).nullable().optional(),
});

type SubRow = { id: string; plan: string; status: string; stripeSubscriptionId: string | null; periodEnd: string | null; cancelAt: string | null };
type GrantRow = { id: string; plan: string; stripe_subscription_id: string; granted_by: string; granted_at: string; until: string | null };

const nowIso = () => new Date().toISOString();

/** The user's live paid subscription rows, best first (resolveTier's order). */
async function liveSubscriptions(db: D1Database, userId: string): Promise<SubRow[]> {
  const placeholders = PAID_SUBSCRIPTION_STATUSES.map(() => "?").join(",");
  const { results } = await db
    .prepare(
      `SELECT "id", "plan", "status", "stripeSubscriptionId", "periodEnd", "cancelAt" FROM "subscription"
        WHERE "referenceId" = ? AND "status" IN (${placeholders})
          AND ("periodEnd" IS NULL OR "periodEnd" > ?)
        ORDER BY CASE "status" WHEN 'active' THEN 0 WHEN 'trialing' THEN 1 ELSE 2 END, "periodEnd" DESC`,
    )
    .bind(userId, ...PAID_SUBSCRIPTION_STATUSES, nowIso())
    .all<SubRow>();
  return results ?? [];
}

async function activeGrants(db: D1Database, userId: string): Promise<GrantRow[]> {
  const { results } = await db
    .prepare(
      `SELECT id, plan, stripe_subscription_id, granted_by, granted_at, until
         FROM plan_grants WHERE user_id = ? AND revoked_at IS NULL ORDER BY granted_at DESC`,
    )
    .bind(userId)
    .all<GrantRow>();
  return results ?? [];
}

/** The plan's monthly price: the id the catalog sync stored, else its lookup key. */
async function monthlyPrice(stripe: Stripe, plan: PlanRecord): Promise<string | null> {
  if (plan.priceId?.trim()) return plan.priceId.trim();
  const key = lookupKeyFor(plan.name, "month");
  return (await resolveLookupKeys(stripe, [key])).get(key) ?? null;
}

async function ensureCompCoupon(stripe: Stripe): Promise<void> {
  try {
    await stripe.coupons.retrieve(COMP_COUPON_ID);
  } catch (err) {
    if ((err as { code?: string }).code !== "resource_missing") throw err;
    await stripe.coupons.create({
      id: COMP_COUPON_ID,
      name: "Complimentary plan",
      percent_off: 100,
      duration: "forever",
      metadata: { capturecat: "admin-grant" },
    });
  }
}

/** The user's Stripe customer — the stored one if Stripe still has it, else a
 *  new one (with the plugin's `userId` metadata), stored on the user. */
async function ensureCustomer(
  stripe: Stripe,
  db: D1Database,
  user: { id: string; email: string; name: string | null; stripeCustomerId: string | null },
): Promise<string> {
  if (user.stripeCustomerId && !(await stripeCustomerIsGone(stripe, user.stripeCustomerId))) {
    return user.stripeCustomerId;
  }
  const customer = await stripe.customers.create({
    email: user.email,
    ...(user.name ? { name: user.name } : {}),
    metadata: { userId: user.id },
  });
  await db.prepare(`UPDATE "user" SET "stripeCustomerId" = ? WHERE id = ?`).bind(customer.id, user.id).run();
  return customer.id;
}

/** Cancels a grant's Stripe subscription now and closes its rows. A
 *  subscription Stripe no longer has is already over — not an error. */
async function endGrant(stripe: Stripe, db: D1Database, grant: GrantRow, adminId: string): Promise<void> {
  try {
    await stripe.subscriptions.cancel(grant.stripe_subscription_id);
  } catch (err) {
    if ((err as { code?: string }).code !== "resource_missing") throw err;
  }
  const now = nowIso();
  await db.batch([
    db.prepare(`UPDATE plan_grants SET revoked_at = ?, revoked_by = ? WHERE id = ?`).bind(now, adminId, grant.id),
    db
      .prepare(`UPDATE "subscription" SET "status" = 'canceled', "canceledAt" = ?, "endedAt" = ? WHERE "stripeSubscriptionId" = ?`)
      .bind(now, now, grant.stripe_subscription_id),
  ]);
}

/** `until` → a future instant (end of that day, UTC, for a bare date). */
function parseUntil(raw: string | null | undefined): Date | null | "invalid" {
  if (!raw) return null;
  const at = new Date(/^\d{4}-\d{2}-\d{2}$/.test(raw) ? `${raw}T23:59:59Z` : raw);
  if (Number.isNaN(at.getTime()) || at.getTime() <= Date.now() + 60_000) return "invalid";
  return at;
}

const secondsToIso = (s: number | null | undefined) => (typeof s === "number" ? new Date(s * 1000).toISOString() : null);

export function registerUserPlanAdminRoutes(app: App): void {
  app.get("/admin/users/:id/plan", async (c) => {
    const userId = c.req.param("id");
    const user = await c.env.DB.prepare(`SELECT id FROM "user" WHERE id = ?`).bind(userId).first<{ id: string }>();
    if (!user) return c.json({ error: "User not found" }, 404);

    const [subs, grants, plans] = await Promise.all([
      liveSubscriptions(c.env.DB, userId),
      activeGrants(c.env.DB, userId),
      listPlans(c.env.DB, false),
    ]);
    const granted = new Set(grants.map((g) => g.stripe_subscription_id));
    const current = subs[0] ?? null;
    const grant = current ? grants.find((g) => g.stripe_subscription_id === current.stripeSubscriptionId) ?? null : null;
    const grantor = grant
      ? await c.env.DB.prepare(`SELECT email FROM "user" WHERE id = ?`).bind(grant.granted_by).first<{ email: string }>()
      : null;
    return c.json({
      plan: current?.plan ?? "free",
      // "grant" = assigned here; "stripe" = the customer pays (or a comp made
      // in the Stripe Dashboard); "none" = free.
      source: !current ? "none" : granted.has(current.stripeSubscriptionId ?? "") ? "grant" : "stripe",
      status: current?.status ?? null,
      grant: grant
        ? { plan: grant.plan, grantedAt: grant.granted_at, grantedBy: grantor?.email ?? grant.granted_by, until: grant.until }
        : null,
      plans: plans.map((p) => ({ name: p.name, displayName: p.displayName, isActive: p.isActive })),
    });
  });

  app.post("/admin/users/:id/plan", async (c) => {
    const userId = c.req.param("id");
    const admin = c.get("user");
    const parsed = await parseJsonBody(c.req, AssignSchema);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const { plan: planName } = parsed.data;

    const until = parseUntil(parsed.data.until);
    if (until === "invalid") return c.json({ error: "until must be a date in the future" }, 400);

    const user = await c.env.DB.prepare(`SELECT id, email, name, "stripeCustomerId" FROM "user" WHERE id = ?`)
      .bind(userId)
      .first<{ id: string; email: string; name: string | null; stripeCustomerId: string | null }>();
    if (!user) return c.json({ error: "User not found" }, 404);

    const plan = planName === "free" ? null : await planByName(c.env.DB, planName);
    if (planName !== "free" && !plan) return c.json({ error: `No plan named "${planName}"` }, 400);

    const [subs, grants] = await Promise.all([liveSubscriptions(c.env.DB, userId), activeGrants(c.env.DB, userId)]);
    const granted = new Set(grants.map((g) => g.stripe_subscription_id));
    const paying = subs.find((s) => !granted.has(s.stripeSubscriptionId ?? ""));
    if (paying) {
      return c.json(
        {
          error: `This user has a ${paying.plan} subscription in Stripe (${paying.status}). Change or cancel it in Stripe first — assigning here never touches what a customer pays for.`,
        },
        409,
      );
    }

    const stripe = createStripeClient(c.env);

    // Removing: end every grant, done.
    if (!plan) {
      for (const g of grants) await endGrant(stripe, c.env.DB, g, admin.uid);
      await purgePlanCache(userId);
      return c.json({ plan: "free", source: "none", removed: grants.length });
    }

    const price = await monthlyPrice(stripe, plan);
    if (!price) {
      return c.json({ error: `${plan.displayName} has no Stripe price yet — save it in Plans to sync it first.` }, 409);
    }

    await ensureCompCoupon(stripe);
    const customer = await ensureCustomer(stripe, c.env.DB, user);

    // The row id goes on the Stripe object as the plugin's `subscriptionId`,
    // so its webhooks find THIS row instead of creating a second one.
    const rowId = generateId(32);
    const grantId = generateId(16);
    const sub = await stripe.subscriptions.create(
      {
        customer,
        items: [{ price }],
        discounts: [{ coupon: COMP_COUPON_ID }],
        ...(until ? { cancel_at: Math.floor(until.getTime() / 1000) } : {}),
        metadata: { userId, referenceId: userId, subscriptionId: rowId, capturecatGrant: grantId, grantedBy: admin.uid },
      },
      { idempotencyKey: `capturecat-grant-${grantId}` },
    );
    // A $0 first invoice pays itself, so the subscription is active at once.
    // Anything else (an account setting that demands a card, say) is not a
    // plan the user can use: undo it rather than leave a dangling object.
    if (!(PAID_SUBSCRIPTION_STATUSES as readonly string[]).includes(sub.status)) {
      await stripe.subscriptions.cancel(sub.id).catch(() => undefined);
      return c.json({ error: `Stripe left the subscription ${sub.status}; nothing was assigned.` }, 502);
    }

    // The previous grant ends only once the new one exists in Stripe, so a
    // failure above leaves the user exactly where they were.
    for (const g of grants) await endGrant(stripe, c.env.DB, g, admin.uid);

    const item = sub.items.data[0] as (Stripe.SubscriptionItem & { current_period_start?: number; current_period_end?: number }) | undefined;
    const legacy = sub as unknown as { current_period_start?: number; current_period_end?: number };
    const now = nowIso();
    await c.env.DB.batch([
      c.env.DB
        .prepare(
          `INSERT INTO "subscription" ("id", "plan", "referenceId", "stripeCustomerId", "stripeSubscriptionId", "status",
             "periodStart", "periodEnd", "cancelAt", "cancelAtPeriodEnd", "billingInterval")
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'month')`,
        )
        .bind(
          rowId,
          plan.name.toLowerCase(),
          userId,
          customer,
          sub.id,
          sub.status,
          secondsToIso(item?.current_period_start ?? legacy.current_period_start) ?? now,
          secondsToIso(item?.current_period_end ?? legacy.current_period_end),
          secondsToIso(sub.cancel_at),
        ),
      c.env.DB
        .prepare(
          `INSERT INTO plan_grants (id, user_id, plan, stripe_subscription_id, granted_by, granted_at, until)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(grantId, userId, plan.name.toLowerCase(), sub.id, admin.uid, now, until ? until.toISOString() : null),
    ]);
    await purgePlanCache(userId);

    return c.json({
      plan: plan.name.toLowerCase(),
      source: "grant",
      status: sub.status,
      stripeSubscriptionId: sub.id,
      until: until ? until.toISOString() : null,
    });
  });
}
