/**
 * The admin plan editor and its Stripe sync, through the REAL admin routes
 * (requireAuth + the admin role gate), the real migrations (node:sqlite) and
 * the real `stripe` SDK — talking to an in-memory Stripe catalog behind a
 * stubbed `fetch` (test-support/fake-stripe-catalog.ts). Nothing here
 * reaches Stripe or Cloudflare.
 *
 * The console's own form model (apps/admin/src/lib/plan-fields.ts) is
 * imported, so "the editor round-trips every limit" is tested with the code
 * the editor runs.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { FakeStripeCatalog } from "../test-support/fake-stripe-catalog";
import { clearLookupKeyCache } from "../lib/stripe-catalog";
import { FEATURE_KEYS, LIMIT_KEYS } from "../lib/plans";
import {
  FEATURE_FIELDS,
  LIMIT_FIELDS,
  formFromPlan,
  planInputFromForm,
  type AdminPlan,
} from "../../../admin/src/lib/plan-fields";

vi.mock("../lib/auth", () => import("../test-support/fake-session"));
vi.stubGlobal("caches", {
  default: { match: async () => undefined, put: async () => undefined, delete: async () => true },
});

const catalog = new FakeStripeCatalog();
const calls: Array<{ method: string; path: string; body: string }> = [];
vi.stubGlobal(
  "fetch",
  vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const method = init?.method ?? "GET";
    const body = String(init?.body ?? "");
    calls.push({ method, path: url.pathname + url.search, body });
    return (
      catalog.handle(method, url, body) ??
      new Response(JSON.stringify({ error: { message: `fake stripe: unhandled ${method} ${url.pathname}` } }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      })
    );
  }),
);

const { adminRoutes } = await import("./admin");
const { planRoutes } = await import("./plans");

const ADMIN = "admin-user";
const DAY = 86_400_000;

let db: TestD1;
let env: Env;
let app: Hono<{ Bindings: Env; Variables: Variables }>;

beforeEach(() => {
  catalog.reset();
  calls.length = 0;
  clearLookupKeyCache();
  db = createTestD1();
  env = {
    DB: db,
    BETTER_AUTH_URL: "http://localhost:8787",
    STRIPE_SECRET_KEY: "sk_test_offline",
    STRIPE_WEBHOOK_SECRET: "whsec_offline",
  } as unknown as Env;
  const iso = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked, role)
     VALUES (?, 'Admin', 'admin@test.local', 1, ?, ?, 0, 0, 'admin')`,
    ADMIN, iso, iso,
  );
  app = new Hono<{ Bindings: Env; Variables: Variables }>();
  app.route("/api", adminRoutes);
  app.route("/api", planRoutes);
});

function call(method: string, path: string, body?: unknown, as = ADMIN) {
  return app.request(
    `/api${path}`,
    {
      method,
      headers: { Authorization: `Bearer ${as}`, "Content-Type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    },
    env,
  );
}
async function ok<T = Record<string, any>>(res: Response | Promise<Response>, status = 200): Promise<T> {
  const r = await res;
  const body = await r.json();
  expect(r.status, JSON.stringify(body)).toBe(status);
  return body as T;
}
const row = (id: string) => db.query(`SELECT * FROM plan WHERE id = ?`, id)[0] as Record<string, any>;
const stripeWrites = () => calls.filter((c) => c.method !== "GET");
const created = (kind: "products" | "prices" | "coupons") =>
  calls.filter((c) => c.method === "POST" && c.path === `/v1/${kind}`);
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();

/** A "team" plan created through the editor: $29/mo, $290/yr. */
async function createTeam(extra: Record<string, unknown> = {}) {
  const { plan, summary } = await ok(
    call("POST", "/admin/plans", {
      name: "team",
      displayName: "CaptureCat Team",
      description: "For teams.",
      monthlyCents: 2900,
      annualCents: 29000,
      ...extra,
    }),
    201,
  );
  return { plan, summary, id: plan.id as string };
}

/** Production's Pro today: no keys, no stored price — only the env secrets. */
function legacyPro() {
  catalog.addProduct({ id: "prod_legacy", name: "CaptureCat Pro", description: "Everything you need to record and share" });
  catalog.addPrice({ id: "price_legacy_m", product: "prod_legacy", unit_amount: 1000 });
  catalog.addPrice({ id: "price_legacy_y", product: "prod_legacy", unit_amount: 10000, interval: "year" });
  env.STRIPE_PRO_PRICE_ID = "price_legacy_m";
  env.STRIPE_PRO_ANNUAL_PRICE_ID = "price_legacy_y";
  env.STRIPE_PRO_TRIAL_DAYS = "14";
}

describe("save is sync", () => {
  it("creating a priced plan provisions ONE product and keyed prices; saving again changes nothing", async () => {
    const { id, summary, plan } = await createTeam();
    expect(summary.product.action).toBe("created");
    expect(summary.monthly).toMatchObject({ action: "created", amountCents: 2900, lookupKey: "capturecat_team_monthly" });
    expect(summary.annual).toMatchObject({ action: "created", amountCents: 29000, lookupKey: "capturecat_team_yearly" });
    expect(plan).toMatchObject({ isActive: false, monthlyAmountCents: 2900, annualAmountCents: 29000 });

    const product = [...catalog.products.values()];
    expect(product).toHaveLength(1);
    expect(product[0]).toMatchObject({ name: "CaptureCat Team", description: "For teams.", metadata: { plan: "team" } });
    expect(row(id)).toMatchObject({
      stripe_product_id: product[0].id,
      price_id: catalog.keyed("capturecat_team_monthly")[0].id,
      annual_price_id: catalog.keyed("capturecat_team_yearly")[0].id,
    });

    // The editor saves the same plan again: nothing is created or archived.
    calls.length = 0;
    const form = formFromPlan(plan as AdminPlan);
    const again = await ok(call("PUT", `/admin/plans/${id}`, planInputFromForm(form)));
    expect(again.summary).toMatchObject({
      changed: false,
      product: { action: "unchanged" },
      monthly: { action: "reused", archived: null },
      annual: { action: "reused", archived: null },
    });
    expect(stripeWrites()).toEqual([]);

    // So does the ⋯ "Sync with Stripe" re-sync.
    const resync = await ok(call("POST", `/admin/plans/${id}/stripe-sync`));
    expect(resync.summary.changed).toBe(false);
    expect(stripeWrites()).toEqual([]);
    expect(catalog.products.size).toBe(1);
    expect(catalog.prices.size).toBe(2);
    // Saving never puts a plan on sale: that is the admin's switch.
    expect(row(id).is_active).toBe(0);
  });

  it("changing an amount creates a new price, moves the key and archives the old one; subscriptions are untouched", async () => {
    const { id } = await createTeam();
    const oldMonthly = row(id).price_id as string;
    db.query(
      `INSERT INTO "subscription" (id, plan, referenceId, stripeCustomerId, stripeSubscriptionId, status)
       VALUES ('sub_row', 'team', 'someone', 'cus_1', 'sub_1', 'active')`,
    );
    calls.length = 0;

    const { summary } = await ok(call("PUT", `/admin/plans/${id}`, { monthlyCents: 3900 }));
    expect(summary.monthly).toMatchObject({ action: "created", amountCents: 3900, archived: oldMonthly });
    expect(summary.annual.action).toBe("reused");

    const newMonthly = row(id).price_id as string;
    expect(newMonthly).not.toBe(oldMonthly);
    // A partial save keeps everything it did not mention.
    expect(row(id)).toMatchObject({ monthly_amount_cents: 3900, annual_amount_cents: 29000, description: "For teams.", display_name: "CaptureCat Team" });
    expect(catalog.keyed("capturecat_team_monthly").map((p) => p.id)).toEqual([newMonthly]);
    expect(catalog.prices.get(oldMonthly)).toMatchObject({ active: false, lookup_key: null });
    // Existing subscriptions keep their price: nothing touched them.
    expect(calls.some((c) => c.path.startsWith("/v1/subscriptions"))).toBe(false);
    expect(db.query(`SELECT plan, status FROM "subscription"`)).toEqual([{ plan: "team", status: "active" }]);
  });

  it("a currency-only change creates new prices (amount AND currency are compared)", async () => {
    const { id } = await createTeam();
    const before = row(id);
    const { summary } = await ok(call("PUT", `/admin/plans/${id}`, { currency: "eur" }));
    expect(summary.monthly).toMatchObject({ action: "created", amountCents: 2900, currency: "eur", archived: before.price_id });
    expect(summary.annual).toMatchObject({ action: "created", amountCents: 29000, currency: "eur", archived: before.annual_price_id });
    expect(row(id).currency).toBe("eur");
    expect(catalog.prices.get(row(id).price_id)).toMatchObject({ currency: "eur", unit_amount: 2900 });
  });

  it("turning yearly billing off archives the yearly price", async () => {
    const { id } = await createTeam();
    const yearly = row(id).annual_price_id;
    const { summary } = await ok(call("PUT", `/admin/plans/${id}`, { annualCents: null }));
    expect(summary.annual).toMatchObject({ action: "archived", archived: yearly, priceId: null });
    expect(row(id)).toMatchObject({ annual_price_id: null, annual_amount_cents: null });
    expect(catalog.prices.get(yearly)!.active).toBe(false);
  });

  it("a plan created without a price touches nothing in Stripe", async () => {
    const body = await ok(call("POST", "/admin/plans", { name: "enterprise", displayName: "Enterprise" }), 201);
    expect(body.summary).toBeNull();
    expect(stripeWrites()).toEqual([]);
    expect(row(body.plan.id)).toMatchObject({ stripe_product_id: null, is_active: 0 });
  });

  it("the free plan is never sold and cannot be hidden", async () => {
    expect((await call("PUT", "/admin/plans/plan_free", { monthlyCents: 500 })).status).toBe(400);
    expect((await call("POST", "/admin/plans/plan_free/active", { isActive: false })).status).toBe(400);
    expect((await call("POST", "/admin/plans/plan_free/stripe-sync")).status).toBe(400);
    expect(stripeWrites()).toEqual([]);
  });

  it("an old console's price ids are ignored: price ids belong to the sync", async () => {
    const { id } = await createTeam();
    const before = row(id).price_id;
    await ok(call("PUT", `/admin/plans/${id}`, { priceId: "price_attacker", annualPriceId: "price_x" }));
    expect(row(id).price_id).toBe(before);
  });

  it("non-admins get nothing", async () => {
    const iso = new Date().toISOString();
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked) VALUES ('joe', 'Joe', 'j@t', 1, ?, ?, 0, 0)`,
      iso, iso,
    );
    expect((await call("POST", "/admin/plans/plan_pro/stripe-sync", undefined, "joe")).status).toBe(404);
    expect((await call("PUT", "/admin/plans/plan_pro", { monthlyCents: 1 }, "joe")).status).toBe(404);
    expect(stripeWrites()).toEqual([]);
  });
});

describe("adopting production's legacy Pro price", () => {
  it("a blank re-sync keys the env prices in place: NO new price, nobody moved", async () => {
    legacyPro();
    const { summary } = await ok(call("POST", "/admin/plans/plan_pro/stripe-sync"));
    expect(summary.product).toEqual({ id: "prod_legacy", action: "updated" });
    expect(summary.monthly).toMatchObject({ action: "adopted", adoptedFrom: "env", priceId: "price_legacy_m", amountCents: 1000 });
    expect(summary.annual).toMatchObject({ action: "adopted", adoptedFrom: "env", priceId: "price_legacy_y", amountCents: 10000 });
    expect(summary.notes).toContain("Trial of 14 days carried over from STRIPE_PRO_TRIAL_DAYS");
    expect(created("prices")).toEqual([]);
    expect(created("products")).toEqual([]);

    expect(catalog.keyed("capturecat_pro_monthly").map((p) => p.id)).toEqual(["price_legacy_m"]);
    expect(catalog.keyed("capturecat_pro_yearly").map((p) => p.id)).toEqual(["price_legacy_y"]);
    expect(catalog.products.get("prod_legacy")!.metadata.plan).toBe("pro");
    expect(row("plan_pro")).toMatchObject({
      stripe_product_id: "prod_legacy",
      price_id: "price_legacy_m",
      annual_price_id: "price_legacy_y",
      monthly_amount_cents: 1000,
      annual_amount_cents: 10000,
      trial_days: 14,
      is_active: 1,
    });

    // From now on the env secrets are not needed: the keys answer.
    delete env.STRIPE_PRO_PRICE_ID;
    delete env.STRIPE_PRO_ANNUAL_PRICE_ID;
    calls.length = 0;
    const again = await ok(call("POST", "/admin/plans/plan_pro/stripe-sync"));
    expect(again.summary.changed).toBe(false);
    expect(stripeWrites()).toEqual([]);
  });

  it("the editor's first save adopts too — blank prices, or the same prices typed in", async () => {
    legacyPro();
    const { plan } = await ok(call("GET", "/admin/plans")).then((b) => ({ plan: b.plans.find((p: AdminPlan) => p.name === "pro") }));
    const form = formFromPlan(plan);
    expect(form.monthly).toBe(""); // the console never knew the env price
    const blank = await ok(call("PUT", "/admin/plans/plan_pro", planInputFromForm(form)));
    expect(blank.summary.monthly.action).toBe("adopted");
    expect(blank.summary.annual.action).toBe("adopted");
    expect(created("prices")).toEqual([]);
  });

  it("re-sending the row's currency does not re-price an un-keyed price in another currency", async () => {
    catalog.addProduct({ id: "prod_eur", name: "CaptureCat Pro" });
    catalog.addPrice({ id: "price_eur", product: "prod_eur", unit_amount: 900, currency: "eur" });
    env.STRIPE_PRO_PRICE_ID = "price_eur";
    const { summary } = await ok(call("PUT", "/admin/plans/plan_pro", { monthlyCents: null, currency: "usd" }));
    expect(summary.monthly).toMatchObject({ action: "adopted", priceId: "price_eur", currency: "eur" });
    expect(row("plan_pro").currency).toBe("eur");
    expect(created("prices")).toEqual([]);
  });

  it("…and typing the same amounts adopts as well", async () => {
    legacyPro();
    const typed = await ok(call("PUT", "/admin/plans/plan_pro", { monthlyCents: 1000, annualCents: 10000, currency: "usd" }));
    expect(typed.summary.monthly).toMatchObject({ action: "adopted", priceId: "price_legacy_m" });
    expect(typed.summary.annual).toMatchObject({ action: "adopted", priceId: "price_legacy_y" });
    expect(created("prices")).toEqual([]);
  });

  it("a changed amount at adoption creates a new keyed price and archives the env one", async () => {
    legacyPro();
    const { summary } = await ok(call("POST", "/admin/plans/plan_pro/stripe-sync", { monthlyCents: 1200 }));
    expect(summary.monthly).toMatchObject({ action: "created", amountCents: 1200, archived: "price_legacy_m" });
    // A price can never move product: the new one joins the legacy product.
    expect(catalog.prices.get(row("plan_pro").price_id)!.product).toBe("prod_legacy");
    expect(catalog.prices.get("price_legacy_m")!.active).toBe(false);
  });

  it("Sync all: adopts Pro, skips a plan with no price, never touches Free", async () => {
    legacyPro();
    const { results } = await ok(call("POST", "/admin/plans/stripe-sync"));
    expect(results.map((r: { plan: string }) => r.plan).sort()).toEqual(["business", "pro"]);
    const pro = results.find((r: { plan: string }) => r.plan === "pro");
    const business = results.find((r: { plan: string }) => r.plan === "business");
    expect(pro.summary.monthly.action).toBe("adopted");
    expect(business.skipped).toMatch(/no Stripe price yet/);
    expect(created("products")).toEqual([]);
    expect(catalog.products.size).toBe(1);
  });

  it("a product found by its metadata.plan tag is reused, never duplicated", async () => {
    catalog.addProduct({ id: "prod_tagged", name: "CaptureCat Business", metadata: { plan: "business" } });
    const { summary } = await ok(call("PUT", "/admin/plans/plan_business", { monthlyCents: 4900 }));
    // Reused — and given the plan's description, which it lacked.
    expect(summary.product).toEqual({ id: "prod_tagged", action: "updated" });
    expect(catalog.products.get("prod_tagged")!.description).toBe(row("plan_business").description);
    expect(created("products")).toEqual([]);
    expect(row("plan_business").stripe_product_id).toBe("prod_tagged");
  });
});

describe("D1 failure after Stripe succeeded", () => {
  function failBatches() {
    const real = db;
    env.DB = new Proxy(real, {
      get(target, key) {
        if (key === "batch") return async () => { throw new Error("D1_ERROR: injected"); };
        const v = (target as unknown as Record<string | symbol, unknown>)[key];
        return typeof v === "function" ? (v as (...a: unknown[]) => unknown).bind(target) : v;
      },
    }) as unknown as D1Database;
  }

  it("an edit is undone in Stripe: the key goes back, the new price is archived, the old one stays live", async () => {
    const { id } = await createTeam();
    const old = row(id).price_id as string;
    failBatches();
    const res = await call("PUT", `/admin/plans/${id}`, { monthlyCents: 3900 });
    expect(res.status).toBe(500);
    expect(((await res.json()) as { error: string }).error).toMatch(/Stripe changes were undone/);

    expect(row(id).price_id).toBe(old);
    expect(catalog.keyed("capturecat_team_monthly").map((p) => p.id)).toEqual([old]);
    expect(catalog.prices.get(old)!.active).toBe(true);
    const fresh = [...catalog.prices.values()].filter((p) => p.unit_amount === 3900);
    expect(fresh).toHaveLength(1);
    expect(fresh[0].active).toBe(false);
  });

  it("a create is undone in Stripe: product, prices and coupons", async () => {
    failBatches();
    const res = await call("POST", "/admin/plans", {
      name: "team",
      displayName: "Team",
      monthlyCents: 2900,
      salePriceMonthlyCents: 1900,
      saleEndsAt: iso(7 * DAY),
    });
    expect(res.status).toBe(500);
    expect(db.query(`SELECT 1 FROM plan WHERE name = 'team'`)).toEqual([]);
    expect([...catalog.products.values()].every((p) => !p.active)).toBe(true);
    expect([...catalog.prices.values()].every((p) => !p.active)).toBe(true);
    expect(catalog.coupons.size).toBe(0);
  });
});

describe("sales: a price for a period, as Stripe coupons", () => {
  it("a sale creates one coupon per interval: amount off, redeem_by = the end, forever, on the plan's product", async () => {
    const end = iso(7 * DAY);
    const { id } = await createTeam({
      saleLabel: "Launch price",
      salePriceMonthlyCents: 1900,
      salePriceAnnualCents: 19000,
      saleEndsAt: end,
    });
    const r = row(id);
    const monthly = catalog.coupons.get(r.stripe_sale_coupon_id)!;
    const annual = catalog.coupons.get(r.stripe_sale_annual_coupon_id)!;
    expect(monthly).toMatchObject({
      name: "Launch price",
      amount_off: 1000,
      currency: "usd",
      duration: "forever",
      duration_in_months: null,
      redeem_by: Math.floor(Date.parse(end) / 1000),
      applies_to: { products: [r.stripe_product_id] },
      metadata: { capturecat_plan: "team", interval: "month" },
    });
    expect(annual).toMatchObject({ amount_off: 10000, metadata: { capturecat_plan: "team", interval: "year" } });
  });

  it("a duration makes it repeating; any change recreates the coupon (they are immutable); a re-save keeps it", async () => {
    const end = iso(7 * DAY);
    const { id } = await createTeam({ salePriceMonthlyCents: 1900, saleEndsAt: end });
    const first = row(id).stripe_sale_coupon_id;

    const { summary } = await ok(call("PUT", `/admin/plans/${id}`, { saleDurationMonths: 3 }));
    expect(summary.monthly.coupon).toMatchObject({ action: "created", replaced: first });
    const second = row(id).stripe_sale_coupon_id;
    expect(catalog.coupons.get(second)).toMatchObject({ duration: "repeating", duration_in_months: 3, amount_off: 1000 });
    expect(catalog.deletedCoupons).toEqual([first]);

    calls.length = 0;
    const again = await ok(call("PUT", `/admin/plans/${id}`, {}));
    expect(again.summary.monthly.coupon).toEqual({ action: "reused", id: second, replaced: null });
    expect(created("coupons")).toEqual([]);

    // A new regular price changes the amount off, so the coupon follows.
    await ok(call("PUT", `/admin/plans/${id}`, { monthlyCents: 3900 }));
    expect(catalog.coupons.get(row(id).stripe_sale_coupon_id)!.amount_off).toBe(2000);
  });

  it("removing the sale, or a sale that has ended, deletes the coupon", async () => {
    const { id } = await createTeam({ salePriceMonthlyCents: 1900, saleEndsAt: iso(7 * DAY) });
    const coupon = row(id).stripe_sale_coupon_id;
    const { summary } = await ok(call("PUT", `/admin/plans/${id}`, { salePriceMonthlyCents: null, saleEndsAt: null }));
    expect(summary.monthly.coupon).toEqual({ action: "deleted", id: null, replaced: coupon });
    expect(row(id).stripe_sale_coupon_id).toBeNull();
    expect(catalog.coupons.size).toBe(0);

    await ok(call("PUT", `/admin/plans/${id}`, { salePriceMonthlyCents: 1900, saleEndsAt: iso(7 * DAY) }));
    expect(catalog.coupons.size).toBe(1);
    await ok(call("PUT", `/admin/plans/${id}`, { saleStartsAt: iso(-3 * DAY), saleEndsAt: iso(-DAY) }));
    expect(row(id).stripe_sale_coupon_id).toBeNull();
    expect(catalog.coupons.size).toBe(0);
  });

  it("invalid sales are refused before Stripe is touched", async () => {
    const { id } = await createTeam();
    calls.length = 0;
    const cases: Array<[Record<string, unknown>, RegExp]> = [
      [{ salePriceMonthlyCents: 1900 }, /needs an end date/],
      [{ salePriceMonthlyCents: 2900, saleEndsAt: iso(DAY) }, /below the monthly price/],
      [{ salePriceAnnualCents: 99999, saleEndsAt: iso(DAY) }, /below the yearly price/],
      [{ salePriceMonthlyCents: 1900, saleStartsAt: iso(2 * DAY), saleEndsAt: iso(DAY) }, /end after it starts/],
    ];
    for (const [patch, message] of cases) {
      const res = await call("PUT", `/admin/plans/${id}`, patch);
      expect(res.status).toBe(400);
      expect(((await res.json()) as { error: string }).error).toMatch(message);
    }
    expect(stripeWrites()).toEqual([]);
  });

  it("the public /api/plans shows the sale price, the regular price and the label only inside the window", async () => {
    // Pro synced at $10, on sale at $7 for a week.
    legacyPro();
    await ok(call("POST", "/admin/plans/plan_pro/stripe-sync"));
    await ok(call("PUT", "/admin/plans/plan_pro", { saleLabel: "Launch price", salePriceMonthlyCents: 700, saleEndsAt: iso(7 * DAY) }));

    const during = await app.request("/api/plans", {}, env);
    const body = (await during.json()) as Record<string, any>;
    expect(body.monthly).toMatchObject({ amount: 700, regularAmount: 1000 });
    expect(body.annual.regularAmount).toBeUndefined();
    expect(body.sale).toMatchObject({ label: "Launch price", durationMonths: null });
    expect(Number(/max-age=(\d+)/.exec(during.headers.get("Cache-Control")!)![1])).toBeLessThanOrEqual(300);

    // Not started yet: regular price, and the cache ends when the sale starts.
    await ok(call("PUT", "/admin/plans/plan_pro", { saleStartsAt: iso(60_000), saleEndsAt: iso(7 * DAY) }));
    const before = await app.request("/api/plans", {}, env);
    const b2 = (await before.json()) as Record<string, any>;
    expect(b2.monthly.amount).toBe(1000);
    expect(b2.monthly.regularAmount).toBeUndefined();
    expect(b2.sale).toBeNull();
    expect(Number(/max-age=(\d+)/.exec(before.headers.get("Cache-Control")!)![1])).toBeLessThanOrEqual(60);
  });
});

describe("the plan editor", () => {
  it("has a field for every feature and limit the API enforces", () => {
    expect(FEATURE_FIELDS.map((f) => f.key).sort()).toEqual([...FEATURE_KEYS].sort());
    expect(LIMIT_FIELDS.map((l) => l.key).sort()).toEqual([...LIMIT_KEYS].sort());
  });

  it("round-trips every limit key, including maxHistoryDays and maxNamedVersions", async () => {
    const { plans } = await ok(call("GET", "/admin/plans"));
    const pro = plans.find((p: AdminPlan) => p.name === "pro") as AdminPlan;
    const form = formFromPlan(pro);
    const next = Object.fromEntries(LIMIT_FIELDS.map((l, i) => [l.key, 1000 + i]));
    form.limits = { ...form.limits, ...next, maxHistoryDays: 90, maxNamedVersions: 40 };
    form.features = { ...form.features, sso: true };
    // Pro has no Stripe price in this fixture; give it one so the save is a
    // real sync, not a no-op.
    form.monthly = "10";

    const { plan } = await ok(call("PUT", "/admin/plans/plan_pro", planInputFromForm(form)));
    expect(plan.limits).toEqual({ ...next, maxHistoryDays: 90, maxNamedVersions: 40 });
    expect(plan.features.sso).toBe(true);
    const reread = (await ok(call("GET", "/admin/plans"))).plans.find((p: AdminPlan) => p.name === "pro");
    expect(formFromPlan(reread).limits).toEqual(form.limits);
  });

  it("hide / publish and Most popular never call Stripe", async () => {
    await ok(call("POST", "/admin/plans/plan_pro/active", { isActive: false }));
    expect(row("plan_pro").is_active).toBe(0);
    await ok(call("POST", "/admin/plans/plan_pro/active", { isActive: true }));
    await ok(call("POST", "/admin/plans/plan_pro/popular", { popular: true }));
    await ok(call("POST", "/admin/plans/plan_business/popular", { popular: true }));
    expect(db.query(`SELECT name FROM plan WHERE popular = 1`)).toEqual([{ name: "business" }]);
    expect(calls).toEqual([]);
  });
});
