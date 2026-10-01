import { describe, expect, it } from "vitest";
import { couponSpec, currentPrices, nextSaleBoundary, saleActive, saleCheckoutParams, saleProblem, type PlanSale } from "./plan-sale";

const NOW = Date.parse("2026-10-01T12:00:00Z");
const H = 3_600_000;
const at = (ms: number) => new Date(NOW + ms).toISOString();

const plan = (over: Partial<PlanSale> = {}): PlanSale => ({
  monthlyAmountCents: 1000,
  annualAmountCents: 10000,
  salePriceMonthlyCents: 700,
  salePriceAnnualCents: null,
  saleStartsAt: null,
  saleEndsAt: at(24 * H),
  stripeSaleCouponId: "coupon_m",
  stripeSaleAnnualCouponId: null,
  ...over,
});

describe("sale window", () => {
  it("is open from the start (or from saving) until the end, exclusive", () => {
    expect(saleActive(plan(), NOW)).toBe(true);
    expect(saleActive(plan({ saleStartsAt: at(H) }), NOW)).toBe(false);
    expect(saleActive(plan({ saleStartsAt: at(-H) }), NOW)).toBe(true);
    expect(saleActive(plan({ saleEndsAt: at(0) }), NOW)).toBe(false);
    expect(saleActive(plan({ saleEndsAt: null }), NOW)).toBe(false); // an endless sale is not a sale
    expect(saleActive(plan({ salePriceMonthlyCents: null }), NOW)).toBe(false);
  });

  it("prices: the sale price only for an interval with its coupon and a lower price", () => {
    expect(currentPrices(plan(), NOW)).toEqual({ monthly: 700, annual: 10000, regularMonthly: 1000, regularAnnual: null, onSale: true });
    expect(currentPrices(plan({ stripeSaleCouponId: null }), NOW).onSale).toBe(false);
    expect(currentPrices(plan({ salePriceMonthlyCents: 1000 }), NOW).onSale).toBe(false);
    expect(currentPrices(plan({ saleEndsAt: at(-1) }), NOW)).toMatchObject({ monthly: 1000, onSale: false });
  });

  it("checkout params: the coupon and an expiry inside Stripe's 31 min – 24 h bounds, capped at the end", () => {
    const s = Math.floor(NOW / 1000);
    expect(saleCheckoutParams(plan({ saleEndsAt: at(2 * H) }), false, NOW)).toEqual({
      discounts: [{ coupon: "coupon_m" }],
      expires_at: s + 7200,
    });
    expect(saleCheckoutParams(plan({ saleEndsAt: at(60_000) }), false, NOW).expires_at).toBe(s + 31 * 60);
    expect(saleCheckoutParams(plan({ saleEndsAt: at(72 * H) }), false, NOW).expires_at).toBe(s + 24 * 3600 - 60);
    expect(saleCheckoutParams(plan(), true, NOW)).toEqual({}); // no annual sale
    expect(saleCheckoutParams(plan({ saleStartsAt: at(H) }), false, NOW)).toEqual({});
  });

  it("the next boundary bounds caching", () => {
    expect(nextSaleBoundary(plan({ saleStartsAt: at(H) }), NOW)).toBe(NOW + H);
    expect(nextSaleBoundary(plan(), NOW)).toBe(NOW + 24 * H);
    expect(nextSaleBoundary(plan({ saleEndsAt: at(-H) }), NOW)).toBeNull();
  });
});

describe("sale coupons", () => {
  it("forever by default, repeating for N months, redeem_by = the end, null once over", () => {
    expect(couponSpec(1000, 700, at(H), null, "usd", "Launch", NOW)).toEqual({
      amountOff: 300,
      currency: "usd",
      months: null,
      redeemBy: Math.floor((NOW + H) / 1000),
      name: "Launch",
    });
    expect(couponSpec(1000, 700, at(H), 3, "usd", null, NOW)).toMatchObject({ months: 3, name: "Sale price" });
    expect(couponSpec(1000, 700, at(-1), null, "usd", null, NOW)).toBeNull();
    expect(couponSpec(1000, 1000, at(H), null, "usd", null, NOW)).toBeNull();
    expect(couponSpec(null, 700, at(H), null, "usd", null, NOW)).toBeNull();
  });

  it("validation: an end, after the start, below the regular price", () => {
    const base = { monthlyCents: 1000, annualCents: 10000 };
    expect(saleProblem({ ...base })).toBeNull();
    expect(saleProblem({ ...base, salePriceMonthlyCents: 700 })).toMatch(/end date/);
    expect(saleProblem({ ...base, salePriceMonthlyCents: 700, saleStartsAt: at(H), saleEndsAt: at(0) })).toMatch(/after it starts/);
    expect(saleProblem({ ...base, salePriceMonthlyCents: 1000, saleEndsAt: at(H) })).toMatch(/below the monthly/);
    expect(saleProblem({ ...base, annualCents: null, salePriceAnnualCents: 1, saleEndsAt: at(H) })).toMatch(/below the yearly/);
    expect(saleProblem({ ...base, salePriceMonthlyCents: 700, saleEndsAt: at(H) })).toBeNull();
  });
});
