/**
 * CaptureCat's Stripe layer — now a thin wrapper around the official
 * `@better-auth/stripe` plugin.
 *
 * WHAT THIS FILE USED TO BE: a hand-rolled `verifyStripeSignature()` HMAC
 * verifier, paired with `src/routes/webhooks.ts`, which mutated Firebase
 * custom claims and kept a `stripe_customers` mapping table in D1.
 *
 * ALL OF THAT IS GONE:
 *   • Signature verification  -> `stripe.webhooks.constructEventAsync()`,
 *     which the plugin prefers when available (WebCrypto, Workers-safe).
 *   • checkout.session.completed / customer.subscription.updated /
 *     customer.subscription.deleted -> the plugin's own handlers, which write
 *     the `subscription` table. Those are EXACTLY the three events our route
 *     handled, so nothing of ours survives. The plugin additionally handles
 *     customer.subscription.created, which we never did.
 *   • Firebase custom claims + refresh-token revocation -> deleted concepts.
 *     Entitlement is now read from the `subscription` table on every request
 *     (see `hasPaidSubscription`), so a cancellation revokes on the very next
 *     API call with no cache to invalidate.
 *   • `stripe_customers` (uid -> customer id) -> replaced by
 *     `subscription.referenceId` (= Better Auth `user.id`) and
 *     `user.stripeCustomerId`, both owned by the plugin.
 *
 * OWNERSHIP NOTE: `buildStripePlugin()` is the ONLY thing `src/lib/auth.ts`
 * should import from here. It exists so the Stripe configuration lives in one
 * file rather than being inlined into the Better Auth instance.
 */

import { stripe as stripePlugin } from "@better-auth/stripe";
import type { DBFieldAttribute } from "better-auth/db";
import { planByName, stripePlansFromDB } from "./plans";
import { saleCheckoutParams } from "./plan-sale";
import { applyCatalogEvent, CATALOG_EVENTS, freshCatalogObject, resolveLookupKeys } from "./stripe-catalog";
import Stripe from "stripe";

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

/**
 * The slice of the Worker `Env` this module needs. Declared locally (rather
 * than importing `Env` from ../types) so the Stripe layer stays decoupled from
 * the auth/identity bindings; `Env` is structurally compatible.
 */
export interface StripeEnv {
  /** Plans live in D1 now, so building the plugin needs the binding. */
  DB: D1Database;
  /** Secret — `sk_live_…` / `sk_test_…`. */
  STRIPE_SECRET_KEY: string;
  /** Secret — `whsec_…` from the /api/auth/stripe/webhook endpoint. */
  STRIPE_WEBHOOK_SECRET: string;
  /** LEGACY — read only by the admin sync's one-time adoption step
   *  (lib/stripe-catalog.ts), never by checkout. Delete the secrets once
   *  every plan is synced; see docs/stripe-setup.md. */
  STRIPE_PRO_PRICE_ID?: string;
  STRIPE_PRO_ANNUAL_PRICE_ID?: string;
  STRIPE_PRO_TRIAL_DAYS?: string;
}

// ---------------------------------------------------------------------------
// Plans
// ---------------------------------------------------------------------------
//
// Plans, prices and trials come from the `plan` table only (`plans:` below,
// via lib/plans.ts `stripePlansFromDB`), and the table's prices are kept in
// step with Stripe by lib/stripe-catalog.ts. There is no hard-coded plan and
// no env-var price on the checkout path.
//
// Free subscriptions, the plugin's own way: a plan row's `trial_days`. A
// trial is a REAL Stripe subscription in status `trialing`, which is already
// in PAID_SUBSCRIPTION_STATUSES — so `resolveTier()` reports "paid" for the
// duration with no extra code and no second source of truth. That is why
// there is no locally-granted "comped" flag: the subscription table is
// written solely by the webhook, and anything written beside it would be a
// paid state Stripe never agrees with.
//
// For one-off comps rather than a blanket trial, do it in Stripe: every user
// already has a stripeCustomerId (createCustomerOnSignUp), so a subscription
// with a 100%-off coupon syncs through the same webhook.
//
// No `seatPriceId` — per-seat billing requires the organization plugin,
// which is not enabled (the plugin logs an error at init if you set it).

// ---------------------------------------------------------------------------
// Entitlement policy — the single definition of "this subscription is paid"
// ---------------------------------------------------------------------------

/**
 * Stripe subscription statuses that grant paid entitlement.
 *
 * `past_due` is included ON PURPOSE: it preserves the dunning grace period the
 * pre-Better-Auth `stripe_customers` policy had — Stripe is still retrying the
 * card, so we do not yank access mid-retry. Note this is intentionally MORE
 * permissive than Better Auth's own `isActiveOrTrialing()` helper, which is
 * `status === "active" || status === "trialing"`. Do not "fix" that divergence
 * without deciding to change the dunning behaviour.
 *
 * Everything else — canceled, unpaid, incomplete, incomplete_expired, paused —
 * revokes.
 */
export const PAID_SUBSCRIPTION_STATUSES = [
  "active",
  "trialing",
  "past_due",
] as const;

/**
 * The entitlement hot path: does this Better Auth user have a paid
 * subscription right now?
 *
 * `subscription.referenceId` is deliberately NOT unique — a user who cancels
 * and resubscribes gets a second row — so this is an existence check, not a
 * single-row status read. One prepared D1 statement; do not route this through
 * `auth.api.listActiveSubscriptions()`, which adds an adapter round trip (and
 * applies Better Auth's stricter active/trialing rule).
 *
 * Throws on D1 failure; callers decide the fail-open/fail-closed posture.
 */
/** The plan NAME of the user's live subscription (lowercased by the plugin),
 *  or null. This is what makes multi-plan gating work: "paid" is a tier,
 *  but WHICH paid plan decides the feature set (pro vs business). */
export async function activeSubscriptionPlan(
  db: D1Database,
  referenceId: string,
): Promise<string | null> {
  const placeholders = PAID_SUBSCRIPTION_STATUSES.map(() => "?").join(",");
  // Precedence by STATUS first, recency second. Ordering by periodEnd alone
  // let a lapsed-into-past_due Business row outrank a freshly bought Pro row
  // (the dunning row's period had already been advanced by Stripe), so the
  // customer paid for Pro and was served Business.
  const row = await db
    .prepare(
      `SELECT "plan" FROM "subscription"
        WHERE "referenceId" = ?
          AND "status" IN (${placeholders})
          AND ${PERIOD_STILL_OPEN}
        ORDER BY CASE "status" WHEN 'active' THEN 0 WHEN 'trialing' THEN 1 ELSE 2 END,
                 "periodEnd" DESC
        LIMIT 1`,
    )
    .bind(referenceId, ...PAID_SUBSCRIPTION_STATUSES, nowIso())
    .first<{ plan: string }>();
  return row?.plan ?? null;
}

/**
 * A paid status alone is not enough: the row's billing period must still be
 * open. This is what bounds `past_due` — Stripe advances periodEnd at each
 * renewal attempt, so a card that keeps failing stays paid only until the
 * period it last managed to open runs out — and it is the backstop for a
 * missed `customer.subscription.deleted` webhook, which would otherwise leave
 * an `active` row granting access forever.
 *
 * `periodEnd` is written by @better-auth/stripe as an ISO-8601 string; rows
 * with no period (never synced) are given the benefit of the doubt so a
 * webhook ordering hiccup cannot lock out a customer who just paid.
 */
const PERIOD_STILL_OPEN = `("periodEnd" IS NULL OR "periodEnd" > ?)`;
const nowIso = () => new Date().toISOString();

export async function hasPaidSubscription(
  db: D1Database,
  referenceId: string,
): Promise<boolean> {
  // Placeholders are generated from PAID_SUBSCRIPTION_STATUSES rather than
  // written out as a SQL literal, so the policy above is the only definition
  // and the two cannot drift.
  const placeholders = PAID_SUBSCRIPTION_STATUSES.map(() => "?").join(",");
  const row = await db
    .prepare(
      `SELECT 1 AS one FROM "subscription"
        WHERE "referenceId" = ?
          AND "status" IN (${placeholders})
          AND ${PERIOD_STILL_OPEN}
        LIMIT 1`,
    )
    .bind(referenceId, ...PAID_SUBSCRIPTION_STATUSES, nowIso())
    .first<{ one: number }>();
  return row !== null;
}

// ---------------------------------------------------------------------------
// Stripe client
// ---------------------------------------------------------------------------

/**
 * Workers-safe Stripe client.
 *
 * `httpClient: Stripe.createFetchHttpClient()` is passed explicitly. The
 * package's `workerd` export condition already resolves to the fetch/WebCrypto
 * build, so this is belt-and-braces — but it means the client still works if a
 * bundler ever resolves the Node build, where the default http client would
 * try to reach for `node:http`.
 *
 * `apiVersion` is pinned to the version stripe@20 ships with, so an SDK bump
 * cannot silently change the wire format. Note a newer string (e.g.
 * `2026-06-24.dahlia`) requires the v22 SDK and is a type error here.
 */
export function createStripeClient(env: StripeEnv): Stripe {
  // The constructor throws when the key is absent. A half-configured
  // environment must not take down EVERY auth request (sign-in included), so
  // fall back to a placeholder — Stripe calls then fail individually.
  const apiKey = env.STRIPE_SECRET_KEY?.trim();
  if (!apiKey) {
    console.error("stripe: STRIPE_SECRET_KEY is not set — all Stripe calls will fail");
  }

  return new Stripe(apiKey || "sk_unconfigured", {
    apiVersion: "2026-02-25.clover",
    httpClient: Stripe.createFetchHttpClient(),
    appInfo: { name: "CaptureCat API", url: "https://capturecat.so" },
  });
}

/**
 * Subscription and catalog webhooks act on Stripe's CURRENT state, never the
 * event's copy.
 *
 * Stripe does not deliver events in order, and a delivery we failed (a 5xx,
 * a 429) is retried hours or days later with its ORIGINAL payload. The
 * plugin writes `event.data.object` straight onto the subscription row, so a
 * late `customer.subscription.updated` (status active, period still open)
 * landing after `customer.subscription.deleted` would resurrect a cancelled
 * — possibly refunded — subscription until its period end. Re-reading the
 * subscription after the signature check makes every such event idempotent
 * and order-independent. A failed re-read fails the delivery (the plugin
 * answers 400) so Stripe retries it, rather than applying the stale copy.
 *
 * The same goes for `product.updated` / `price.*`: an old price event must
 * not put back an amount the owner has since changed. A product or price
 * that no longer exists arrives as the event's copy marked `deleted`.
 *
 * `client.webhooks` is Stripe's SHARED static object, so the override goes on
 * a per-client child of it rather than mutating it for every instance.
 */
export function withFreshEvents(client: Stripe): Stripe {
  const shared = client.webhooks;
  const webhooks = Object.create(shared) as Stripe.Webhooks;
  webhooks.constructEventAsync = async (...args: Parameters<Stripe.Webhooks["constructEventAsync"]>) => {
    const event = await shared.constructEventAsync(...args);
    if (event.type.startsWith("customer.subscription.")) {
      const stale = event.data.object as Stripe.Subscription;
      (event.data as { object: Stripe.Subscription }).object = await client.subscriptions.retrieve(stale.id);
    } else if (CATALOG_EVENTS.has(event.type)) {
      await freshCatalogObject(client, event);
    }
    return event;
  };
  client.webhooks = webhooks;
  return client;
}

/**
 * A chargeback takes the money back; the service it paid for must not keep
 * running on it. Without this a customer could pay, dispute the charge, and
 * keep the plan until the period ends — a full year on an annual price.
 * Cancelling in Stripe (rather than writing the row) keeps Stripe the single
 * source of truth: the resulting `customer.subscription.deleted` is what
 * revokes access, through the plugin like any other cancellation.
 *
 * Inquiries (`warning_*` statuses) move no money and are left alone. Every
 * live subscription of the disputing customer is cancelled: a CaptureCat
 * customer is one user, and a charge no longer names its invoice on this API
 * version. Idempotent — a retried delivery skips what is already cancelled.
 */
export async function cancelDisputedSubscriptions(client: Stripe, dispute: Stripe.Dispute): Promise<string[]> {
  if (dispute.status.startsWith("warning_")) return [];
  const chargeId = typeof dispute.charge === "string" ? dispute.charge : dispute.charge.id;
  const charge = await client.charges.retrieve(chargeId);
  const customer = typeof charge.customer === "string" ? charge.customer : charge.customer?.id;
  if (!customer) return [];
  const cancelled: string[] = [];
  for await (const sub of client.subscriptions.list({ customer, status: "all", limit: 100 })) {
    if (sub.status === "canceled" || sub.status === "incomplete_expired") continue;
    await client.subscriptions.cancel(sub.id, {
      cancellation_details: { comment: `Charge ${chargeId} disputed (${dispute.id})` },
    });
    cancelled.push(sub.id);
  }
  console.log(`stripe: dispute ${dispute.id} on ${customer} — cancelled ${cancelled.join(", ") || "nothing"}`);
  return cancelled;
}

/** Whether any subscription this customer EVER had (cancelled ones
 *  included) started a trial. */
async function customerHadTrial(client: Stripe, customer: string): Promise<boolean> {
  for await (const sub of client.subscriptions.list({ customer, status: "all", limit: 100 })) {
    if (sub.trial_start) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// THE PLUGIN BLOCK — imported by src/lib/auth.ts
// ---------------------------------------------------------------------------

/**
 * Build the configured `@better-auth/stripe` plugin.
 *
 * >>> This is the ONLY export `src/lib/auth.ts` needs. Drop it straight into
 * >>> the `plugins: [...]` array:
 * >>>
 * >>>     plugins: [bearer(), oneTimeToken({...}), buildStripePlugin(env)]
 * >>>
 * >>> Do not configure Stripe inline in auth.ts.
 *
 * Endpoints this registers under `basePath` (`/api/auth`):
 *   POST /subscription/upgrade         POST /subscription/cancel
 *   POST /subscription/restore         POST /subscription/billing-portal
 *   GET  /subscription/list            GET  /subscription/success
 *   POST /stripe/webhook
 *
 * The webhook endpoint is declared `cloneRequest: true, disableBody: true` and
 * reads `ctx.request.text()`, so NOTHING may consume the request body before
 * `auth.handler(c.req.raw)` in src/index.ts.
 */
/**
 * A user's saved Stripe customer that does not exist for THIS Stripe key —
 * created under another key or mode (accounts that signed up before the live
 * key was set) or deleted in the Dashboard. The plugin would otherwise fail
 * every checkout and portal visit with "No such customer" forever.
 *
 * True only when Stripe itself says so (`resource_missing`, or a deleted
 * customer); any other error (network, auth) is not "gone" — the caller
 * leaves the id alone and the plugin reports the real failure.
 */
export async function stripeCustomerIsGone(client: Stripe, customerId: string): Promise<boolean> {
  try {
    const customer = await client.customers.retrieve(customerId);
    return "deleted" in customer && customer.deleted === true;
  } catch (err) {
    return (err as { code?: string } | null)?.code === "resource_missing";
  }
}

export function buildStripePlugin(env: StripeEnv) {
  const client = withFreshEvents(createStripeClient(env));
  return lockStripeCustomerId(stripePlugin({
    stripeClient: client,
    stripeWebhookSecret: env.STRIPE_WEBHOOK_SECRET,

    // Create the Stripe customer at sign-up so `user.stripeCustomerId` is
    // populated before the first checkout. Replaces the old flow where the
    // customer id only appeared after checkout.session.completed.
    createCustomerOnSignUp: true,

    // No `getCustomerCreateParams` override: the plugin already sends
    // `email`, `name`, and `metadata: { userId, customerType: "user" }`, which
    // is everything we need to trace a Stripe customer back to a user row.

    onCustomerCreate: async ({ stripeCustomer, user }) => {
      console.log(`stripe: customer ${stripeCustomer.id} created for user ${user.id}`);
    },

    subscription: {
      enabled: true,
      // Read from the `plan` table ONLY, so tiers and prices are edited in
      // the admin console (and synced to Stripe) without a deploy. The
      // plugin re-invokes this per request that needs it, so an edit takes
      // effect immediately.
      //
      // There is deliberately no fallback plan. The old one sold the env
      // price whenever the table offered nothing — including for a Pro row
      // the admin had HIDDEN (security fix #9). Hidden rows are never
      // offered: hidden means not for sale.
      //
      // A failed read offers nothing rather than throwing. Checkout then
      // refuses the plan; the subscription webhooks still record status
      // changes (an unmatched price keeps the row's plan), where a throw
      // would make the plugin drop the event.
      plans: async () => {
        try {
          const plans = await stripePlansFromDB(env, (keys) => resolveLookupKeys(client, keys));
          if (plans.length === 0) console.error("stripe: no sellable plans in the plan table");
          return plans;
        } catch (err) {
          console.error("stripe: plan lookup failed — nothing is for sale this request", err);
          return [];
        }
      },

      // Sign-in is social-only (Google/Apple), both of which return a verified
      // email, so gating on verification would be a no-op.
      requireEmailVerification: false,

      // ONE free trial per Stripe customer, decided from Stripe's history.
      // The plugin grants a trial when no LOCAL subscription row carries
      // trial dates — but its own /subscription/cancel deletes a row whose
      // Stripe subscription is no longer active, so trial → cancel → cancel
      // endpoint → upgrade was an endless series of free trials. Stripe keeps
      // cancelled subscriptions (and their trial_start) forever. Returning an
      // explicit `trial_period_days: undefined` overrides the plugin's
      // row-based grant (the key is then omitted from the request).
      //
      // A SALE rides here too: while the plan's sale window is open, the
      // session gets that interval's coupon and an expiry no later than the
      // sale's end (lib/plan-sale.ts), so a page opened at the sale price
      // cannot be paid at it a day later. Everyone is on the regular price;
      // the coupon is the discount, and Stripe itself refuses it after its
      // redeem_by. The plan row is re-read so the window is decided now.
      getCheckoutSessionParams: async ({ user, plan, subscription }, _request, ctx) => {
        const annual = (ctx?.body as { annual?: unknown } | undefined)?.annual === true;
        const row = await planByName(env.DB, plan.name);
        const sale = row ? saleCheckoutParams(row, annual, Date.now()) : {};

        let noTrial = false;
        if (plan.freeTrial) {
          const customer = subscription.stripeCustomerId ?? (user as { stripeCustomerId?: string }).stripeCustomerId;
          noTrial = !!customer && (await customerHadTrial(client, customer));
        }
        if (!noTrial && !sale.discounts) return {};
        return {
          params: {
            ...sale,
            ...(noTrial ? { subscription_data: { trial_period_days: undefined } } : {}),
          },
        };
      },

      // Lifecycle logging only. State persistence is the plugin's job — these
      // hooks must NOT write entitlement anywhere, because the `subscription`
      // table is the single source of truth read per-request.
      onSubscriptionComplete: async ({ subscription }) => {
        console.log(
          `stripe: user ${subscription.referenceId} subscribed to ${subscription.plan} (${subscription.status})`,
        );
      },
      onSubscriptionUpdate: async ({ subscription }) => {
        console.log(
          `stripe: user ${subscription.referenceId} subscription -> ${subscription.status}`,
        );
      },
      onSubscriptionCancel: async ({ subscription }) => {
        console.log(
          `stripe: user ${subscription.referenceId} scheduled cancellation (ends ${subscription.periodEnd?.toISOString() ?? "unknown"})`,
        );
      },
      onSubscriptionDeleted: async ({ subscription }) => {
        console.log(
          `stripe: user ${subscription.referenceId} subscription deleted — access revoked on next request`,
        );
      },

      // `referenceId` defaults to `session.user.id` for customerType "user".
      // No `authorizeReference` callback is needed because clients never send
      // an explicit referenceId (and must not — see docs/stripe-setup.md).
    },

    /**
     * Catch-all for events the plugin does not own. It also fires AFTER each
     * owned handler, so filter to avoid double-logging.
     *
     * Nothing from the old `routes/webhooks.ts` lives here — the plugin covers
     * all three events it handled. This is the hook to extend if we ever want
     * `invoice.paid`, `invoice.payment_failed`, dunning email, etc.
     *
     * `charge.dispute.created` IS handled: see cancelDisputedSubscriptions.
     * So are the catalog events (`product.updated`, `price.created`,
     * `price.updated`, `price.deleted`): they keep the plan table's names,
     * amounts and price ids in step with edits made in the Stripe
     * Dashboard — see applyCatalogEvent in lib/stripe-catalog.ts.
     * A throw here makes the plugin answer 400, so Stripe retries.
     */
    onEvent: async (event) => {
      if (event.type === "charge.dispute.created") {
        await cancelDisputedSubscriptions(client, event.data.object as Stripe.Dispute);
        return;
      }
      if (CATALOG_EVENTS.has(event.type)) {
        console.log(`stripe: ${event.type} (${event.id}) — ${await applyCatalogEvent(client, env.DB, event)}`);
        return;
      }
      const OWNED = new Set([
        "checkout.session.completed",
        "customer.subscription.created",
        "customer.subscription.updated",
        "customer.subscription.deleted",
      ]);
      if (!OWNED.has(event.type)) {
        console.log(`stripe: unhandled event ${event.type} (${event.id})`);
      }
    },
  }));
}

/**
 * SECURITY: the plugin declares `user.stripeCustomerId` WITHOUT `input:
 * false`, and Better Auth treats every plugin user field as client-settable
 * unless told otherwise — so POST /api/auth/update-user could re-point the
 * caller at ANOTHER user's Stripe customer. From there: checkout runs on the
 * victim's customer (their saved cards), the billing portal opens the
 * victim's billing, a dashboard-created comp for the victim maps to the
 * attacker, and the plugin's own user-update hook rewrites the victim
 * customer's email to the attacker's. The plugin writes this column itself
 * through the internal adapter, which `input: false` does not affect.
 *
 * Plugin fields override `user.additionalFields`, and the plugin's
 * `schema` option can only rename columns, so the flag is set here on a
 * copy of the plugin's schema. src/lib/auth.test.ts pins it.
 */
function lockStripeCustomerId<P extends ReturnType<typeof stripePlugin>>(plugin: P): P {
  const user = plugin.schema.user;
  const locked = { ...user.fields.stripeCustomerId, input: false } satisfies DBFieldAttribute;
  plugin.schema = {
    ...plugin.schema,
    user: { ...user, fields: { ...user.fields, stripeCustomerId: locked } },
  } as P["schema"];
  return plugin;
}
