/**
 * Time-limited sales — "a price for a period" — as pure rules.
 *
 * A sale never creates a cheaper Stripe price. Everyone is on the plan's
 * REGULAR price; the discount is a Stripe coupon (one per interval) that
 * checkout adds while the sale is on. The coupon's `redeem_by` is the sale's
 * end, so Stripe itself refuses it afterwards, and its `duration` says how
 * long the discount lasts for someone who joined in time: `forever`, or
 * `repeating` for N months. Stripe shows the discount, and how long it lasts,
 * on the checkout page and on every invoice.
 *
 * Checkout (lib/stripe.ts), the public /api/plans and the admin console all
 * read the same answers from here, so the site can never advertise a price
 * checkout would not charge. Ported from the owner's other app (xtra,
 * packages/core/src/billing-rules.ts).
 */

export interface PlanSale {
  monthlyAmountCents: number | null;
  annualAmountCents: number | null;
  salePriceMonthlyCents: number | null;
  salePriceAnnualCents: number | null;
  saleStartsAt: string | null;
  saleEndsAt: string | null;
  /** An interval without its coupon is never on sale: the coupon is what
   *  checkout charges, so a sale without one is not shown either. */
  stripeSaleCouponId: string | null;
  stripeSaleAnnualCouponId: string | null;
}

const ms = (iso: string | null | undefined) => (iso ? Date.parse(iso) : Number.NaN);

/**
 * Whether the sale window is open at `now`. A sale needs an end: a "normally
 * $99" with no end would be a fake reference price. No start = on from the
 * moment it is saved.
 */
export function saleActive(p: PlanSale, now: number): boolean {
  if (p.salePriceMonthlyCents == null && p.salePriceAnnualCents == null) return false;
  const end = ms(p.saleEndsAt);
  if (!Number.isFinite(end) || now >= end) return false;
  const start = ms(p.saleStartsAt);
  return !Number.isFinite(start) || now >= start;
}

/**
 * What the plan costs at `now`, per interval: the sale price while the sale
 * is on (lower, and with its coupon in place), else the regular price.
 * `regular*` is set only while a sale lowers that interval — it is what the
 * site strikes through.
 */
export function currentPrices(p: PlanSale, now: number): {
  monthly: number | null;
  annual: number | null;
  regularMonthly: number | null;
  regularAnnual: number | null;
  onSale: boolean;
} {
  const open = saleActive(p, now);
  const monthlyOnSale =
    open &&
    !!p.stripeSaleCouponId &&
    p.salePriceMonthlyCents != null &&
    p.monthlyAmountCents != null &&
    p.salePriceMonthlyCents < p.monthlyAmountCents;
  const annualOnSale =
    open &&
    !!p.stripeSaleAnnualCouponId &&
    p.salePriceAnnualCents != null &&
    p.annualAmountCents != null &&
    p.salePriceAnnualCents < p.annualAmountCents;
  return {
    monthly: monthlyOnSale ? p.salePriceMonthlyCents : p.monthlyAmountCents,
    annual: annualOnSale ? p.salePriceAnnualCents : p.annualAmountCents,
    regularMonthly: monthlyOnSale ? p.monthlyAmountCents : null,
    regularAnnual: annualOnSale ? p.annualAmountCents : null,
    onSale: monthlyOnSale || annualOnSale,
  };
}

/** The coupon checkout applies to one interval at `now`, or null when that
 *  interval is not on sale. */
export function saleCoupon(p: PlanSale, annual: boolean, now: number): string | null {
  const price = currentPrices(p, now);
  if (annual) return price.regularAnnual != null ? p.stripeSaleAnnualCouponId : null;
  return price.regularMonthly != null ? p.stripeSaleCouponId : null;
}

/** Stripe's bounds on a Checkout Session's `expires_at`: 30 minutes to 24
 *  hours out (a minute of margin either side). */
const SESSION_MIN_S = 31 * 60;
const SESSION_MAX_S = 24 * 60 * 60 - 60;

/**
 * Extra Checkout Session params while a sale is on: the coupon, and an expiry
 * no later than the sale's end (Stripe's 30-minute floor aside), so a
 * checkout page opened before the end cannot be paid at the sale price a day
 * later. Outside a sale: nothing, and the session keeps Stripe's defaults.
 */
export function saleCheckoutParams(
  p: PlanSale,
  annual: boolean,
  now: number,
): { discounts?: Array<{ coupon: string }>; expires_at?: number } {
  const coupon = saleCoupon(p, annual, now);
  const end = ms(p.saleEndsAt);
  if (!coupon || !Number.isFinite(end)) return {};
  const nowS = Math.floor(now / 1000);
  const endS = Math.floor(end / 1000);
  return {
    discounts: [{ coupon }],
    expires_at: Math.min(nowS + SESSION_MAX_S, Math.max(nowS + SESSION_MIN_S, endS)),
  };
}

/** The next moment the public price changes (a sale starting or ending), or
 *  null. Bounds how long /api/plans may be cached. */
export function nextSaleBoundary(p: PlanSale, now: number): number | null {
  if (p.salePriceMonthlyCents == null && p.salePriceAnnualCents == null) return null;
  const times = [ms(p.saleStartsAt), ms(p.saleEndsAt)].filter((t) => Number.isFinite(t) && t > now);
  return times.length > 0 ? Math.min(...times) : null;
}

/**
 * Why a sale cannot be saved, or null. A sale needs an end date (an endless
 * "normally $99" would be a fake reference price), must end after it starts,
 * and has to lower the price it discounts. `monthly`/`annual` are the regular
 * prices the sale will discount.
 */
export function saleProblem(p: {
  monthlyCents: number | null | undefined;
  annualCents: number | null | undefined;
  salePriceMonthlyCents?: number | null;
  salePriceAnnualCents?: number | null;
  saleStartsAt?: string | null;
  saleEndsAt?: string | null;
}): string | null {
  if (p.salePriceMonthlyCents == null && p.salePriceAnnualCents == null) return null;
  if (!p.saleEndsAt) return "A sale needs an end date.";
  if (p.saleStartsAt && Date.parse(p.saleStartsAt) >= Date.parse(p.saleEndsAt)) {
    return "The sale has to end after it starts.";
  }
  if (p.salePriceMonthlyCents != null && (p.monthlyCents == null || p.salePriceMonthlyCents >= p.monthlyCents)) {
    return "The monthly sale price has to be below the monthly price.";
  }
  if (p.salePriceAnnualCents != null && (p.annualCents == null || p.salePriceAnnualCents >= p.annualCents)) {
    return "The yearly sale price has to be below the yearly price.";
  }
  return null;
}

/** What one interval's sale coupon is. Stripe coupons are immutable apart
 *  from their name, so any other difference means a new coupon. */
export interface CouponSpec {
  amountOff: number;
  currency: string;
  /** null = `forever`; N = `repeating` for N months. */
  months: number | null;
  /** Unix seconds: the sale's end. */
  redeemBy: number;
  name: string;
}

/**
 * The coupon one interval's sale needs, or null for none: no sale price, one
 * that is not lower, or an end that has already passed (Stripe refuses a
 * `redeem_by` in the past, and the sale is over anyway).
 */
export function couponSpec(
  regular: number | null | undefined,
  sale: number | null | undefined,
  endsAt: string | null | undefined,
  months: number | null | undefined,
  currency: string,
  label: string | null | undefined,
  now: number,
): CouponSpec | null {
  const end = ms(endsAt);
  if (regular == null || sale == null || sale >= regular || !Number.isFinite(end) || end <= now) return null;
  return {
    amountOff: regular - sale,
    currency,
    months: months ?? null,
    redeemBy: Math.floor(end / 1000),
    name: (label?.trim() || "Sale price").slice(0, 40),
  };
}
