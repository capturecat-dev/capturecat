/**
 * The plan table ⇄ the Stripe product catalog.
 *
 * WHY. Checkout used to sell whatever `STRIPE_PRO_PRICE_ID` named, and the
 * admin "Sync with Stripe" button minted a new product and new prices on every
 * click. Now the plan table says WHAT is sold and for how much, saving a plan
 * in the admin console makes Stripe match, and the two are joined by stable
 * names, never pasted ids:
 *
 *   product  ONE per plan: `plan.stripe_product_id`, tagged `metadata.plan`.
 *   price    found by lookup key, `capturecat_<plan>_monthly` / `_yearly`
 *            (`lookupKeyFor` in lib/plans.ts). Stripe keeps a lookup key on
 *            exactly one price, so "the price for Pro monthly" is a question
 *            Stripe can answer.
 *   sale     a coupon per interval on the regular price (lib/plan-sale.ts).
 *
 * Ways in:
 *
 *   provisionPlan        DB → Stripe, on every admin save. Reads first, then
 *                        makes only ADDITIVE changes; the caller writes D1 and
 *                        then calls `finish()` (archive what was replaced) or,
 *                        if D1 failed, `rollback()` — so a failure in between
 *                        never leaves Stripe selling something D1 does not
 *                        know about. Idempotent: a re-save reuses everything.
 *   syncPlanToStripe     the same, for the "Sync with Stripe" button (a
 *                        re-save without edits — and the one-time adoption of
 *                        the legacy env prices).
 *   applyCatalogEvent    Stripe → DB (webhooks). Keeps names, amounts and the
 *                        active price ids current when the owner edits the
 *                        catalog in the Stripe Dashboard.
 *   resolveLookupKeys    checkout, for a sellable row with no stored price.
 *
 * Prices are immutable in Stripe, so "change the price" is: create a new
 * price, move the lookup key onto it (`transfer_lookup_key`), archive the old
 * one. Existing subscriptions stay on the price they were sold — Stripe never
 * moves a subscriber because a price was archived — and keep resolving to
 * their plan through the `plan` name on their subscription row.
 */

import type Stripe from "stripe";
import {
  listPlans,
  lookupKeyFor,
  parseLookupKey,
  planById,
  planByName,
  type BillingInterval,
  type PlanRecord,
} from "./plans";
import { couponSpec, saleProblem, type CouponSpec } from "./plan-sale";

/** The pre-sync env secrets. Read ONLY by the adoption step below, so the
 *  first sync can key the price production already sells (moving nobody);
 *  once every plan is synced they can be deleted. */
export interface LegacyPriceEnv {
  STRIPE_PRO_PRICE_ID?: string;
  STRIPE_PRO_ANNUAL_PRICE_ID?: string;
  STRIPE_PRO_TRIAL_DAYS?: string;
}

function errMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function isMissing(err: unknown): boolean {
  return (err as { statusCode?: number } | null)?.statusCode === 404;
}

function productIdOf(price: Stripe.Price): string {
  return typeof price.product === "string" ? price.product : price.product.id;
}

/** A price is ours to sell for `interval` only if it is a plain licensed,
 *  fixed-amount, every-1-interval recurring price. */
function isPlainRecurring(price: Stripe.Price, interval: BillingInterval): boolean {
  return (
    price.type === "recurring" &&
    price.recurring?.interval === interval &&
    (price.recurring.interval_count ?? 1) === 1 &&
    price.recurring.usage_type !== "metered" &&
    typeof price.unit_amount === "number"
  );
}

// ---------------------------------------------------------------------------
// Checkout: lookup key → active price id, cached per isolate
// ---------------------------------------------------------------------------

/** Short on purpose: a price changed in the Stripe Dashboard is picked up by
 *  the next isolate within a minute even if its webhook never arrives. */
const LOOKUP_TTL_MS = 60_000;
const lookupCache = new Map<string, { id: string | null; at: number }>();

/** Drop the cache (after this isolate changed the catalog itself). */
export function clearLookupKeyCache(): void {
  lookupCache.clear();
}

/**
 * Lookup keys → ACTIVE price ids of the right interval. Never throws: a
 * Stripe hiccup means "no price found" (the plan is not offered for that
 * request) rather than an error on every path that lists plans.
 */
export async function resolveLookupKeys(client: Stripe, keys: string[]): Promise<Map<string, string>> {
  const now = Date.now();
  const out = new Map<string, string>();
  const stale: string[] = [];
  for (const key of new Set(keys)) {
    const hit = lookupCache.get(key);
    if (hit && now - hit.at < LOOKUP_TTL_MS) {
      if (hit.id) out.set(key, hit.id);
    } else {
      stale.push(key);
    }
  }
  // Stripe accepts at most 10 lookup keys per list call.
  for (let i = 0; i < stale.length; i += 10) {
    const batch = stale.slice(i, i + 10);
    try {
      const { data } = await client.prices.list({ lookup_keys: batch, active: true, limit: 100 });
      for (const key of batch) {
        const interval = parseLookupKey(key)?.interval;
        const price = data.find((p) => p.lookup_key === key && !!interval && isPlainRecurring(p, interval));
        lookupCache.set(key, { id: price?.id ?? null, at: now });
        if (price) out.set(key, price.id);
      }
    } catch (err) {
      console.error("stripe: lookup-key resolution failed", errMessage(err));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// DB → Stripe
// ---------------------------------------------------------------------------

/** Refused for a reason the admin can act on (HTTP 400/404/409), as opposed
 *  to a Stripe or D1 failure. */
export class SyncRefusedError extends Error {
  constructor(message: string, readonly status: 400 | 404 | 409 | 503 = 400) {
    super(message);
  }
}

/** What the admin wants the plan to be. */
export interface DesiredPlan {
  name: string;
  displayName: string;
  description: string | null;
  /**
   * Per interval, in minor units:
   *   undefined  keep what Stripe already charges (adopt / reuse as-is);
   *   null       stop selling this interval (archive its price). A blank
   *              field for a price the console never knew (D1 has no amount)
   *              means undefined, not null: you cannot remove what you could
   *              not see, and that is exactly the legacy env price;
   *   number     this amount.
   */
  monthlyCents: number | null | undefined;
  annualCents: number | null | undefined;
  /** ISO currency, lowercase. undefined = the existing price's, else the row's. */
  currency: string | undefined;
  trialDays: number;
  sale: {
    label: string | null;
    monthlyCents: number | null;
    annualCents: number | null;
    startsAt: string | null;
    endsAt: string | null;
    durationMonths: number | null;
  };
}

export type ProductAction = "created" | "updated" | "unchanged";
/**
 *   adopted   an existing un-keyed price (the row's, or the legacy env one)
 *             was given the lookup key — no new price, nobody moved.
 *   created   a new price was created and the lookup key moved onto it; the
 *             one it replaced (if any) is in `archived`.
 *   reused    the keyed price already matched.
 *   archived  this interval is no longer sold; its price was archived.
 *   none      no price, before or after.
 */
export type PriceAction = "adopted" | "created" | "reused" | "archived" | "none";
export type CouponAction = "created" | "reused" | "deleted" | "none";

export interface PriceSyncResult {
  interval: BillingInterval;
  lookupKey: string;
  action: PriceAction;
  priceId: string | null;
  amountCents: number | null;
  currency: string | null;
  /** The price archived (`active: false`) by this sync. Its subscribers keep
   *  paying it. */
  archived: string | null;
  adoptedFrom?: "plan" | "env";
  /** The sale coupon for this interval. */
  coupon: { action: CouponAction; id: string | null; replaced: string | null };
}

export interface PlanSyncSummary {
  planId: string;
  plan: string;
  /** False when the sync changed nothing in Stripe or D1. */
  changed: boolean;
  product: { id: string; action: ProductAction };
  monthly: PriceSyncResult;
  annual: PriceSyncResult;
  /** Human-readable extras: duplicates found, prices that could not be
   *  archived, legacy settings carried over. */
  notes: string[];
}

/** The plan-row columns provisioning owns. */
export interface StripeColumns {
  stripe_product_id: string;
  price_id: string | null;
  annual_price_id: string | null;
  monthly_amount_cents: number | null;
  annual_amount_cents: number | null;
  currency: string;
  stripe_sale_coupon_id: string | null;
  stripe_sale_annual_coupon_id: string | null;
  trial_days: number;
}

export interface Provisioned {
  columns: StripeColumns;
  summary: PlanSyncSummary;
  /** D1 is written: archive the prices and delete the coupons this sync
   *  replaced. Failures become notes — a leftover is harmless, since nothing
   *  sells it any more. */
  finish(): Promise<void>;
  /** D1 could not be written: undo every Stripe change this sync made, so
   *  nothing is left that D1 does not know about. Best effort; never throws. */
  rollback(): Promise<void>;
}

interface IntervalState {
  interval: BillingInterval;
  key: string;
  /** The price holding the lookup key (active or not), if any. */
  keyed: Stripe.Price | null;
  /** Only when nothing is keyed: a known price to adopt. */
  candidate: Stripe.Price | null;
  candidateFrom?: "plan" | "env";
}

async function priceByLookupKey(client: Stripe, key: string): Promise<Stripe.Price | null> {
  // No `active` filter: an archived price can still hold the key, and the
  // sync must see it to move the key off it.
  const { data } = await client.prices.list({ lookup_keys: [key], limit: 1 });
  return data.find((p) => p.lookup_key === key) ?? null;
}

async function retrievePrice(client: Stripe, id: string): Promise<Stripe.Price | null> {
  try {
    const price = await client.prices.retrieve(id);
    return (price as { deleted?: boolean }).deleted ? null : price;
  } catch (err) {
    if (isMissing(err)) return null;
    throw err;
  }
}

async function retrieveCoupon(client: Stripe, id: string): Promise<Stripe.Coupon | null> {
  try {
    const coupon = await client.coupons.retrieve(id);
    return (coupon as { deleted?: boolean }).deleted ? null : coupon;
  } catch (err) {
    if (isMissing(err)) return null;
    throw err;
  }
}

async function intervalState(
  client: Stripe,
  plan: string,
  storedId: string | null | undefined,
  interval: BillingInterval,
  legacy: LegacyPriceEnv,
  notes: string[],
): Promise<IntervalState> {
  const key = lookupKeyFor(plan, interval);
  const keyed = await priceByLookupKey(client, key);
  if (keyed) return { interval, key, keyed, candidate: null };

  const stored = storedId?.trim();
  const env =
    plan === "pro"
      ? (interval === "month" ? legacy.STRIPE_PRO_PRICE_ID : legacy.STRIPE_PRO_ANNUAL_PRICE_ID)?.trim()
      : undefined;
  const sources: Array<[string, "plan" | "env"]> = [];
  if (stored) sources.push([stored, "plan"]);
  if (env && env !== stored) sources.push([env, "env"]);
  for (const [id, from] of sources) {
    const price = await retrievePrice(client, id);
    if (!price) {
      notes.push(`${id} (${from === "env" ? "env secret" : "plan row"}) no longer exists in Stripe`);
      continue;
    }
    if (!isPlainRecurring(price, interval)) {
      notes.push(`${id} is not a fixed ${interval}ly price, so it was not adopted`);
      continue;
    }
    return { interval, key, keyed: null, candidate: price, candidateFrom: from };
  }
  return { interval, key, keyed: null, candidate: null };
}

/** Products tagged for this plan, via Search (eventually consistent, and not
 *  available in every region) with a full list as the fallback. */
async function taggedProducts(client: Stripe, plan: string): Promise<Stripe.Product[]> {
  try {
    const res = await client.products.search({ query: `metadata['plan']:'${plan}'`, limit: 100 });
    return res.data.filter((p) => p.metadata?.plan === plan);
  } catch (err) {
    console.warn("stripe-sync: product search failed, listing instead", errMessage(err));
    const found: Stripe.Product[] = [];
    for await (const p of client.products.list({ limit: 100 })) {
      if (p.metadata?.plan === plan) found.push(p);
    }
    return found;
  }
}

async function retrieveProduct(client: Stripe, id: string): Promise<Stripe.Product | null> {
  try {
    const product = await client.products.retrieve(id);
    return (product as { deleted?: boolean }).deleted ? null : product;
  } catch (err) {
    if (isMissing(err)) return null;
    throw err;
  }
}

/**
 * The plan's ONE product: the stored id; else the product of a price this
 * plan already sells (subscribers are on it, and a price can never move to
 * another product); else one tagged `metadata.plan`; else none yet.
 */
async function findProduct(
  client: Stripe,
  storedId: string | null,
  plan: string,
  states: IntervalState[],
  notes: string[],
): Promise<Stripe.Product | null> {
  if (storedId) {
    const stored = await retrieveProduct(client, storedId);
    if (stored) return stored;
    notes.push(`Stored product ${storedId} no longer exists in Stripe`);
  }
  const anchor = states.map((s) => s.keyed ?? s.candidate).find((p): p is Stripe.Price => !!p);
  if (anchor) {
    const product = await retrieveProduct(client, productIdOf(anchor));
    if (product) return product;
  }
  const tagged = await taggedProducts(client, plan);
  const pick = tagged.find((p) => p.active) ?? tagged[0] ?? null;
  const extra = tagged.filter((p) => p !== pick).map((p) => p.id);
  if (extra.length > 0) {
    notes.push(`Other products are also tagged plan=${plan} (${extra.join(", ")}); archive them in Stripe`);
  }
  return pick;
}

/** One interval's decision, made before anything is written. */
interface IntervalPlan {
  state: IntervalState;
  /** null = not sold on this interval after the sync. */
  amount: number | null;
  currency: string | null;
}

/**
 * Make Stripe match `desired` for the plan `current` (null = a plan not yet
 * in D1). Returns null when there is nothing to provision (no price, no
 * product, nothing to archive) — a plan that is not sold yet.
 *
 * Reads everything first and refuses before writing anything; then makes
 * only additive changes (create, key, rename), recording how to undo each.
 * Archiving and deleting what was replaced waits for `finish()`.
 */
export async function provisionPlan(
  client: Stripe,
  db: D1Database,
  current: PlanRecord | null,
  desired: DesiredPlan,
  legacy: LegacyPriceEnv = {},
  now: number = Date.now(),
): Promise<Provisioned | null> {
  if (desired.name === "free") throw new SyncRefusedError("The free plan is never sold");
  const notes: string[] = [];

  // ---- read: what Stripe holds ---------------------------------------------
  const states = [
    await intervalState(client, desired.name, current?.priceId, "month", legacy, notes),
    await intervalState(client, desired.name, current?.annualPriceId, "year", legacy, notes),
  ];
  const plans: IntervalPlan[] = states.map((state) => {
    const monthly = state.interval === "month";
    const recorded = monthly ? current?.monthlyAmountCents : current?.annualAmountCents;
    let requested = monthly ? desired.monthlyCents : desired.annualCents;
    if (requested === null && recorded == null) requested = undefined;
    const existing = state.keyed ?? state.candidate;
    if (requested === null) return { state, amount: null, currency: null };
    let amount: number | null;
    if (requested === undefined) {
      if (existing && existing.unit_amount == null) {
        throw new SyncRefusedError(`${existing.id} has no fixed amount: enter the ${state.interval}ly price to replace it`);
      }
      amount = existing ? existing.unit_amount : recorded ?? null;
    } else {
      amount = requested;
    }
    // "As-is" keeps the existing price's currency too: a form that merely
    // re-sends the row's currency must not re-price an un-keyed price that
    // happens to be in another one.
    const currency = (
      requested === undefined && existing
        ? existing.currency
        : (desired.currency ?? existing?.currency ?? current?.currency ?? "usd")
    ).toLowerCase();
    return { state, amount, currency: amount === null ? null : currency };
  });
  const [m, y] = plans;
  if (m.currency && y.currency && m.currency !== y.currency) {
    throw new SyncRefusedError("The monthly and yearly prices must be in the same currency");
  }
  const problem = saleProblem({
    monthlyCents: m.amount,
    annualCents: y.amount,
    salePriceMonthlyCents: desired.sale.monthlyCents,
    salePriceAnnualCents: desired.sale.annualCents,
    saleStartsAt: desired.sale.startsAt,
    saleEndsAt: desired.sale.endsAt,
  });
  if (problem) throw new SyncRefusedError(problem);

  const anyExisting = states.some((s) => s.keyed ?? s.candidate);
  if (m.amount === null && y.amount === null && !anyExisting && !current?.stripeProductId) return null;

  let product = await findProduct(client, current?.stripeProductId ?? null, desired.name, states, notes);
  if (product) {
    const owner = await db
      .prepare(`SELECT name FROM plan WHERE stripe_product_id = ? AND id != ?`)
      .bind(product.id, current?.id ?? "")
      .first<{ name: string }>();
    const tag = product.metadata?.plan;
    if (owner || (tag && tag !== desired.name)) {
      throw new SyncRefusedError(
        `Stripe product ${product.id} belongs to plan "${owner?.name ?? tag}"; give "${desired.name}" its own product`,
        409,
      );
    }
  }
  const couponIds = [current?.stripeSaleCouponId ?? null, current?.stripeSaleAnnualCouponId ?? null];
  const coupons = await Promise.all(couponIds.map((id) => (id ? retrieveCoupon(client, id) : null)));
  couponIds.forEach((id, i) => {
    if (id && !coupons[i]) notes.push(`Sale coupon ${id} no longer exists in Stripe`);
  });

  // ---- write: additive only, each with its undo ----------------------------
  const undo: Array<() => Promise<unknown>> = [];
  const cleanup: Array<{ what: string; run: () => Promise<unknown> }> = [];
  const rollback = async () => {
    for (const step of undo.reverse()) {
      await step().catch((err) => console.error("stripe-sync: rollback step failed", errMessage(err)));
    }
    undo.length = 0;
    clearLookupKeyCache();
  };

  try {
    let productAction: ProductAction = "unchanged";
    if (product) {
      const before = product;
      const patch: Stripe.ProductUpdateParams = {};
      if (product.name !== desired.displayName) patch.name = desired.displayName;
      if (desired.description && product.description !== desired.description) patch.description = desired.description;
      if (product.metadata?.plan !== desired.name) patch.metadata = { plan: desired.name };
      if (!product.active) patch.active = true;
      if (Object.keys(patch).length > 0) {
        product = await client.products.update(product.id, patch);
        productAction = "updated";
        undo.push(() =>
          client.products.update(before.id, {
            name: before.name,
            ...(patch.description ? { description: before.description ?? "" } : {}),
            ...(patch.metadata ? { metadata: { plan: before.metadata?.plan ?? "" } } : {}),
            ...(patch.active ? { active: false } : {}),
          }),
        );
      }
    } else {
      product = await client.products.create({
        name: desired.displayName,
        ...(desired.description ? { description: desired.description } : {}),
        metadata: { plan: desired.name },
      });
      productAction = "created";
      const created = product.id;
      undo.push(() => client.products.update(created, { active: false }));
    }
    const productId = product.id;

    const results: PriceSyncResult[] = [];
    for (const [i, { state: s, amount, currency }] of plans.entries()) {
      const existing = s.keyed ?? s.candidate;
      const base = { interval: s.interval, lookupKey: s.key, archived: null as string | null };
      let price: Omit<PriceSyncResult, "coupon">;

      if (amount === null) {
        if (existing?.active) {
          cleanup.push({ what: `archive ${existing.id}`, run: () => client.prices.update(existing.id, { active: false }) });
          price = { ...base, action: "archived", priceId: null, amountCents: null, currency: null, archived: existing.id };
        } else {
          price = { ...base, action: "none", priceId: null, amountCents: null, currency: null };
        }
      } else {
        const matches = (p: Stripe.Price) =>
          p.active &&
          productIdOf(p) === productId &&
          isPlainRecurring(p, s.interval) &&
          p.unit_amount === amount &&
          p.currency === currency;
        if (s.keyed && matches(s.keyed)) {
          price = { ...base, action: "reused", priceId: s.keyed.id, amountCents: amount, currency };
        } else if (s.candidate && matches(s.candidate)) {
          const adopted = s.candidate.id;
          await client.prices.update(adopted, { lookup_key: s.key, transfer_lookup_key: true });
          undo.push(() => client.prices.update(adopted, { lookup_key: "" }));
          price = { ...base, action: "adopted", priceId: adopted, amountCents: amount, currency, adoptedFrom: s.candidateFrom };
        } else {
          const created = await client.prices.create({
            product: productId,
            unit_amount: amount,
            currency: currency!,
            recurring: { interval: s.interval },
            lookup_key: s.key,
            transfer_lookup_key: true,
            nickname: `${desired.displayName}, ${s.interval === "month" ? "monthly" : "yearly"}`,
            metadata: { plan: desired.name },
          });
          const previousHolder = s.keyed?.id;
          undo.push(async () => {
            if (previousHolder) {
              await client.prices.update(previousHolder, { lookup_key: s.key, transfer_lookup_key: true });
            }
            await client.prices.update(created.id, { active: false });
          });
          let archived: string | null = null;
          if (existing?.active && existing.id !== created.id) {
            archived = existing.id;
            cleanup.push({ what: `archive ${existing.id}`, run: () => client.prices.update(existing.id, { active: false }) });
          }
          price = { ...base, action: "created", priceId: created.id, amountCents: amount, currency, archived };
        }
      }

      // The sale coupon rides on the price just settled.
      const sale = desired.sale;
      const want: CouponSpec | null =
        price.amountCents === null
          ? null
          : couponSpec(
              price.amountCents,
              s.interval === "month" ? sale.monthlyCents : sale.annualCents,
              sale.endsAt,
              sale.durationMonths,
              price.currency!,
              sale.label,
              now,
            );
      const had = coupons[i];
      const same =
        !!had &&
        !!want &&
        current?.stripeProductId === productId &&
        had.amount_off === want.amountOff &&
        had.currency === want.currency &&
        had.duration === (want.months ? "repeating" : "forever") &&
        (had.duration_in_months ?? null) === want.months &&
        had.redeem_by === want.redeemBy;
      let coupon: PriceSyncResult["coupon"];
      if (same) {
        if (had.name !== want.name) await client.coupons.update(had.id, { name: want.name });
        coupon = { action: "reused", id: had.id, replaced: null };
      } else if (want) {
        const created = await client.coupons.create({
          name: want.name,
          amount_off: want.amountOff,
          currency: want.currency,
          ...(want.months
            ? { duration: "repeating" as const, duration_in_months: want.months }
            : { duration: "forever" as const }),
          redeem_by: want.redeemBy,
          applies_to: { products: [productId] },
          metadata: { capturecat_plan: desired.name, interval: s.interval },
        });
        undo.push(() => client.coupons.del(created.id));
        if (had) cleanup.push({ what: `delete coupon ${had.id}`, run: () => client.coupons.del(had.id) });
        coupon = { action: "created", id: created.id, replaced: had?.id ?? null };
      } else if (had) {
        // Deleting a coupon never removes the discount from a subscription
        // that already has it; it only stops new redemptions.
        cleanup.push({ what: `delete coupon ${had.id}`, run: () => client.coupons.del(had.id) });
        coupon = { action: "deleted", id: null, replaced: had.id };
      } else {
        coupon = { action: "none", id: null, replaced: null };
      }
      results.push({ ...price, coupon });
    }
    const [monthly, annual] = results;

    // Before the plan table had prices, Pro's trial came from an env var too.
    // Carry it over at the sync that adopts the env prices, so the migration
    // does not silently drop a trial nobody could see in the console.
    let trialDays = desired.trialDays;
    const envTrial = Number.parseInt(legacy.STRIPE_PRO_TRIAL_DAYS ?? "", 10) || 0;
    if (trialDays === 0 && envTrial > 0 && results.some((r) => r.adoptedFrom === "env")) {
      trialDays = envTrial;
      notes.push(`Trial of ${envTrial} days carried over from STRIPE_PRO_TRIAL_DAYS`);
    }

    const columns: StripeColumns = {
      stripe_product_id: productId,
      price_id: monthly.priceId,
      annual_price_id: annual.priceId,
      monthly_amount_cents: monthly.amountCents,
      annual_amount_cents: annual.amountCents,
      currency: monthly.currency ?? annual.currency ?? current?.currency ?? "usd",
      stripe_sale_coupon_id: monthly.coupon.id,
      stripe_sale_annual_coupon_id: annual.coupon.id,
      trial_days: trialDays,
    };
    const dbChanged =
      !current ||
      current.stripeProductId !== columns.stripe_product_id ||
      current.priceId !== columns.price_id ||
      current.annualPriceId !== columns.annual_price_id ||
      current.monthlyAmountCents !== columns.monthly_amount_cents ||
      current.annualAmountCents !== columns.annual_amount_cents ||
      current.currency !== columns.currency ||
      current.stripeSaleCouponId !== columns.stripe_sale_coupon_id ||
      current.stripeSaleAnnualCouponId !== columns.stripe_sale_annual_coupon_id ||
      current.trialDays !== columns.trial_days;
    const summary: PlanSyncSummary = {
      planId: current?.id ?? "",
      plan: desired.name,
      changed:
        dbChanged ||
        productAction !== "unchanged" ||
        results.some((r) => r.action !== "reused" && r.action !== "none") ||
        results.some((r) => r.coupon.action === "created" || r.coupon.action === "deleted"),
      product: { id: productId, action: productAction },
      monthly,
      annual,
      notes,
    };

    return {
      columns,
      summary,
      rollback,
      async finish() {
        undo.length = 0;
        for (const step of cleanup) {
          try {
            await step.run();
          } catch (err) {
            notes.push(`Could not ${step.what}: ${errMessage(err)}`);
          }
        }
        cleanup.length = 0;
        clearLookupKeyCache();
        console.log(
          `stripe-sync: ${desired.name} product ${productId} ${productAction}; ` +
            results
              .map((r) => `${r.interval} ${r.action}${r.archived ? ` (archived ${r.archived})` : ""}, coupon ${r.coupon.action}`)
              .join("; "),
        );
      },
    };
  } catch (err) {
    // A Stripe write failed half-way: put back what this call already did.
    await rollback();
    throw err;
  }
}

/** The Stripe columns, written after `provisionPlan` succeeded. */
export function stripeColumnsUpdate(db: D1Database, planId: string, c: StripeColumns): D1PreparedStatement {
  return db
    .prepare(
      `UPDATE plan SET stripe_product_id = ?, price_id = ?, annual_price_id = ?,
                       monthly_amount_cents = ?, annual_amount_cents = ?, currency = ?,
                       stripe_sale_coupon_id = ?, stripe_sale_annual_coupon_id = ?,
                       trial_days = ?, updated_at = datetime('now')
        WHERE id = ?`,
    )
    .bind(
      c.stripe_product_id,
      c.price_id,
      c.annual_price_id,
      c.monthly_amount_cents,
      c.annual_amount_cents,
      c.currency,
      c.stripe_sale_coupon_id,
      c.stripe_sale_annual_coupon_id,
      c.trial_days,
      planId,
    );
}

/** A plan row as the plan it already is (amounts as-is unless given). */
export function desiredFromRow(
  plan: PlanRecord,
  input: { monthlyCents?: number | null; annualCents?: number | null; currency?: string | null } = {},
): DesiredPlan {
  return {
    name: plan.name,
    displayName: plan.displayName,
    description: plan.description,
    monthlyCents: input.monthlyCents ?? undefined,
    annualCents: input.annualCents ?? undefined,
    currency: input.currency ?? undefined,
    trialDays: plan.trialDays,
    sale: {
      label: plan.saleLabel,
      monthlyCents: plan.salePriceMonthlyCents,
      annualCents: plan.salePriceAnnualCents,
      startsAt: plan.saleStartsAt,
      endsAt: plan.saleEndsAt,
      durationMonths: plan.saleDurationMonths,
    },
  };
}

/**
 * "Sync with Stripe": make Stripe match the plan row as it is. An amount
 * given here replaces that interval's price; one left out keeps (and, the
 * first time, adopts) what Stripe already charges.
 */
export async function syncPlanToStripe(
  client: Stripe,
  db: D1Database,
  planId: string,
  input: { monthlyCents?: number | null; annualCents?: number | null; currency?: string | null } = {},
  legacy: LegacyPriceEnv = {},
): Promise<PlanSyncSummary> {
  const plan = await planById(db, planId);
  if (!plan) throw new SyncRefusedError("Plan not found", 404);
  const provisioned = await provisionPlan(client, db, plan, desiredFromRow(plan, input), legacy);
  if (!provisioned) {
    throw new SyncRefusedError("This plan has no Stripe price yet: set a monthly and/or yearly price");
  }
  try {
    await stripeColumnsUpdate(db, plan.id, provisioned.columns).run();
  } catch (err) {
    await provisioned.rollback();
    throw err;
  }
  await provisioned.finish();
  return provisioned.summary;
}

export interface SyncAllResult {
  planId: string;
  plan: string;
  summary?: PlanSyncSummary;
  /** Nothing to sync (e.g. no price yet) — not an error. */
  skipped?: string;
  error?: string;
}

/** Every plan except free, one at a time. One plan failing does not stop the
 *  others; each result says what happened. */
export async function syncAllPlansToStripe(
  client: Stripe,
  db: D1Database,
  legacy: LegacyPriceEnv = {},
): Promise<SyncAllResult[]> {
  const out: SyncAllResult[] = [];
  for (const plan of await listPlans(db, false)) {
    if (plan.name === "free") continue;
    try {
      out.push({ planId: plan.id, plan: plan.name, summary: await syncPlanToStripe(client, db, plan.id, {}, legacy) });
    } catch (err) {
      if (err instanceof SyncRefusedError) out.push({ planId: plan.id, plan: plan.name, skipped: err.message });
      else out.push({ planId: plan.id, plan: plan.name, error: errMessage(err) });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Stripe → DB: catalog webhooks
// ---------------------------------------------------------------------------

/** Catalog events this module handles. Everything else is not its business. */
export const CATALOG_EVENTS = new Set(["product.updated", "price.created", "price.updated", "price.deleted"]);

/**
 * Apply a VERIFIED catalog event whose object was re-read from Stripe after
 * the signature check (see `withFreshEvents` in lib/stripe.ts), so a late or
 * out-of-order delivery acts on Stripe's current state, never on the copy it
 * carries. A deleted object arrives as `{ …, deleted: true }`.
 *
 * Scope is deliberately narrow:
 *   • only the product a plan row stores (and still tagged `metadata.plan`),
 *     and only prices carrying one of our lookup keys or stored on a row;
 *   • only names, descriptions, price ids and amounts — never `is_active`,
 *     features or limits. A webhook cannot put a plan on sale.
 *
 * Throws on a Stripe or D1 failure, which the plugin answers with a 400 so
 * Stripe redelivers. Returns what it did, for the log.
 */
export async function applyCatalogEvent(client: Stripe, db: D1Database, event: Stripe.Event): Promise<string> {
  if (event.type === "product.updated") {
    return applyProduct(db, event.data.object as Stripe.Product & { deleted?: boolean });
  }
  if (event.type === "price.created" || event.type === "price.updated" || event.type === "price.deleted") {
    return applyPrice(client, db, event.data.object as Stripe.Price & { deleted?: boolean });
  }
  return `ignored ${event.type}`;
}

async function applyProduct(db: D1Database, product: Stripe.Product & { deleted?: boolean }): Promise<string> {
  const row = await db
    .prepare(`SELECT id, name, display_name, description FROM plan WHERE stripe_product_id = ?`)
    .bind(product.id)
    .first<{ id: string; name: string; display_name: string; description: string | null }>();
  if (!row) return `ignored product ${product.id}: no plan uses it`;
  if (product.deleted) return `ignored product ${product.id}: deleted`;
  if (product.metadata?.plan !== row.name) return `ignored product ${product.id}: not tagged plan=${row.name}`;

  const name = product.name?.trim() || row.display_name;
  const description = product.description?.trim() || null;
  if (name === row.display_name && description === row.description) return `plan ${row.name} unchanged`;
  await db
    .prepare(`UPDATE plan SET display_name = ?, description = ?, updated_at = datetime('now') WHERE id = ?`)
    .bind(name, description, row.id)
    .run();
  return `plan ${row.name} renamed from product ${product.id}`;
}

async function applyPrice(client: Stripe, db: D1Database, price: Stripe.Price & { deleted?: boolean }): Promise<string> {
  // Which (plan, interval) pairs could this price affect? Its lookup key, if
  // it is ours — and any row that stores it (it may just have LOST the key,
  // or been archived).
  const affected = new Map<string, { plan: string; interval: BillingInterval }>();
  const keyed = parseLookupKey(price.lookup_key);
  if (keyed) affected.set(`${keyed.plan}:${keyed.interval}`, keyed);
  const { results } = await db
    .prepare(`SELECT name, price_id, annual_price_id FROM plan WHERE price_id = ? OR annual_price_id = ?`)
    .bind(price.id, price.id)
    .all<{ name: string; price_id: string | null; annual_price_id: string | null }>();
  for (const r of results ?? []) {
    if (r.price_id === price.id) affected.set(`${r.name}:month`, { plan: r.name, interval: "month" });
    if (r.annual_price_id === price.id) affected.set(`${r.name}:year`, { plan: r.name, interval: "year" });
  }
  if (affected.size === 0) return `ignored price ${price.id}: not a plan price`;

  const done: string[] = [];
  for (const { plan: name, interval } of affected.values()) {
    const plan = await planByName(db, name);
    if (!plan) {
      done.push(`${name}: no such plan`);
      continue;
    }
    done.push(`${name} ${interval}: ${await reconcileInterval(client, db, plan, interval, price)}`);
  }
  clearLookupKeyCache();
  return done.join("; ");
}

/**
 * Re-derive one plan interval's price from Stripe's CURRENT catalog: the
 * active price holding the lookup key, on the plan's own product. If there is
 * none and the stored price is the one that just went inactive or was
 * deleted, the plan stops being sold on that interval (an archived price
 * cannot be checked out anyway). Anything else is left alone.
 */
async function reconcileInterval(
  client: Stripe,
  db: D1Database,
  plan: PlanRecord,
  interval: BillingInterval,
  seen: Stripe.Price & { deleted?: boolean },
): Promise<string> {
  if (!plan.stripeProductId) return "ignored: plan never synced";
  const key = lookupKeyFor(plan.name, interval);
  const { data } = await client.prices.list({ lookup_keys: [key], active: true, limit: 1 });
  const current = data.find((p) => p.lookup_key === key) ?? null;
  const storedId = interval === "month" ? plan.priceId : plan.annualPriceId;
  const storedAmount = interval === "month" ? plan.monthlyAmountCents : plan.annualAmountCents;

  let next: { id: string | null; amount: number | null; currency: string };
  if (current && productIdOf(current) === plan.stripeProductId && isPlainRecurring(current, interval)) {
    next = { id: current.id, amount: current.unit_amount, currency: current.currency };
  } else if (storedId === seen.id && (seen.deleted || !seen.active)) {
    next = { id: null, amount: null, currency: plan.currency };
  } else {
    return current ? `ignored: ${current.id} is not a plain ${interval}ly price on ${plan.stripeProductId}` : "unchanged";
  }
  if (next.id === storedId && next.amount === storedAmount && next.currency === plan.currency) return "unchanged";

  const [idCol, amountCol] =
    interval === "month" ? ["price_id", "monthly_amount_cents"] : ["annual_price_id", "annual_amount_cents"];
  await db
    .prepare(`UPDATE plan SET ${idCol} = ?, ${amountCol} = ?, currency = ?, updated_at = datetime('now') WHERE id = ?`)
    .bind(next.id, next.amount, next.currency, plan.id)
    .run();
  return next.id ? `now ${next.id} (${next.amount} ${next.currency})` : `no active price (was ${storedId})`;
}

/** For lib/stripe.ts: re-read a catalog object after the signature check.
 *  A deleted object comes back as the event's copy marked `deleted`. */
export async function freshCatalogObject(client: Stripe, event: Stripe.Event): Promise<void> {
  const stale = event.data.object as { id: string };
  const data = event.data as { object: unknown };
  try {
    if (event.type.startsWith("product.")) data.object = await client.products.retrieve(stale.id);
    else if (event.type.startsWith("price.")) data.object = await client.prices.retrieve(stale.id);
  } catch (err) {
    if (!isMissing(err)) throw err;
    data.object = { ...stale, active: false, deleted: true };
  }
}
