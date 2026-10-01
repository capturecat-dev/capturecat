/**
 * Billing through the REAL Better Auth instance + @better-auth/stripe plugin
 * (buildAuth), against the real migrations (node:sqlite). Stripe itself is a
 * small in-memory fake behind a stubbed `fetch`: webhook deliveries are signed
 * with the test secret exactly as Stripe signs them, and every API call the
 * plugin makes is answered — and recorded — locally. Nothing here reaches
 * Stripe or Cloudflare.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import Stripe from "stripe";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { FakeStripeCatalog } from "../test-support/fake-stripe-catalog";
import { buildAuth } from "./auth";
import { hasPaidSubscription } from "./stripe";
import { clearLookupKeyCache } from "./stripe-catalog";
import { resolveEntitlement } from "./entitlement";
import { planForEntitlement } from "./plans";

const WEBHOOK_SECRET = "whsec_offline_test_secret";
const PRICE = "price_pro_monthly";
const PRODUCT = "prod_pro";
const USER = "payer";
const CUSTOMER = "cus_payer";

/** Products, prices and coupons — the catalog the sync and checkout read. */
const catalog = new FakeStripeCatalog();

/** The fake Stripe account: subscriptions + charges, and every call made. */
const fake = vi.hoisted(() => ({
  subscriptions: new Map<string, Record<string, unknown>>(),
  charges: new Map<string, Record<string, unknown>>(),
  /** Customer ids this Stripe account does not have (made under another key). */
  missingCustomers: new Set<string>(),
  createdCustomers: 0,
  calls: [] as Array<{ method: string; path: string; body: string }>,
}));

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

vi.stubGlobal(
  "fetch",
  vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const method = init?.method ?? "GET";
    fake.calls.push({ method, path: url.pathname + url.search, body: String(init?.body ?? "") });
    const fromCatalog = catalog.handle(method, url, String(init?.body ?? ""));
    if (fromCatalog) return fromCatalog;
    const p = url.pathname;
    let m: RegExpExecArray | null;
    if ((m = /^\/v1\/subscriptions\/([^/]+)$/.exec(p))) {
      const sub = fake.subscriptions.get(m[1]);
      if (!sub) return json({ error: { type: "invalid_request_error", code: "resource_missing" } }, 404);
      if (method === "DELETE") {
        sub.status = "canceled";
        sub.ended_at = Math.floor(Date.now() / 1000);
      }
      return json(sub);
    }
    if (p === "/v1/subscriptions") {
      const customer = url.searchParams.get("customer");
      const data = [...fake.subscriptions.values()].filter((s) => s.customer === customer);
      return json({ object: "list", data, has_more: false, url: "/v1/subscriptions" });
    }
    if ((m = /^\/v1\/charges\/([^/]+)$/.exec(p))) return json(fake.charges.get(m[1]));
    if (p === "/v1/checkout/sessions" && method === "POST") {
      return json({ id: "cs_test_1", object: "checkout.session", url: "https://checkout.stripe.test/cs_test_1" });
    }
    if (p === "/v1/customers/search" || (p === "/v1/customers" && method === "GET")) {
      return json({ object: p.endsWith("search") ? "search_result" : "list", data: [], has_more: false, url: p });
    }
    if (p === "/v1/customers" && method === "POST") {
      const id = `cus_new_${++fake.createdCustomers}`;
      return json({ id, object: "customer", email: `${USER}@test.local`, metadata: {} });
    }
    if ((m = /^\/v1\/customers\/([^/]+)$/.exec(p))) {
      if (fake.missingCustomers.has(m[1])) {
        return json({ error: { type: "invalid_request_error", code: "resource_missing", message: `No such customer: '${m[1]}'` } }, 404);
      }
      return json({ id: m[1], object: "customer", email: `${USER}@test.local`, metadata: {} });
    }
    return json({ error: { message: `fake stripe: unhandled ${method} ${p}` } }, 500);
  }),
);

let db: TestD1;
let env: Env;
const now = () => Math.floor(Date.now() / 1000);
const DAY = 86_400;

function subscriptionObject(status: string, extra: Record<string, unknown> = {}) {
  return {
    id: "sub_1",
    object: "subscription",
    customer: CUSTOMER,
    status,
    metadata: { subscriptionId: "row_1", referenceId: USER, userId: USER },
    cancel_at_period_end: false,
    cancel_at: null,
    canceled_at: status === "canceled" ? now() - 60 : null,
    ended_at: status === "canceled" ? now() - 60 : null,
    trial_start: null,
    trial_end: null,
    schedule: null,
    items: {
      object: "list",
      data: [
        {
          id: "si_1",
          quantity: 1,
          price: { id: PRICE, recurring: { interval: "month" } },
          current_period_start: now() - 5 * DAY,
          current_period_end: now() + 25 * DAY,
        },
      ],
    },
    ...extra,
  };
}

beforeEach(() => {
  fake.subscriptions.clear();
  fake.charges.clear();
  fake.missingCustomers.clear();
  fake.createdCustomers = 0;
  fake.calls.length = 0;
  catalog.reset();
  clearLookupKeyCache();
  db = createTestD1();
  // No STRIPE_PRO_PRICE_ID / STRIPE_PRO_ANNUAL_PRICE_ID: checkout must work
  // from the plan table alone.
  env = {
    DB: db,
    BETTER_AUTH_URL: "http://localhost:8787",
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
    GOOGLE_CLIENT_ID: "google-test",
    GOOGLE_CLIENT_SECRET: "google-test-secret",
    STRIPE_SECRET_KEY: "sk_test_offline",
    STRIPE_WEBHOOK_SECRET: WEBHOOK_SECRET,
  } as unknown as Env;
  // Pro as the admin sync leaves it: one product, a keyed monthly price,
  // both stored on the row.
  catalog.addProduct({ id: PRODUCT, name: "CaptureCat Pro", metadata: { plan: "pro" } });
  catalog.addPrice({ id: PRICE, product: PRODUCT, unit_amount: 1000, lookup_key: "capturecat_pro_monthly" });
  db.query(
    `UPDATE plan SET stripe_product_id = ?, price_id = ?, monthly_amount_cents = 1000 WHERE name = 'pro'`,
    PRODUCT, PRICE,
  );
  const iso = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, stripeCustomerId, tester, blocked)
     VALUES (?, 'Payer', ?, 1, ?, ?, ?, 0, 0)`,
    USER, `${USER}@test.local`, iso, iso, CUSTOMER,
  );
  db.query(
    `INSERT INTO "session" (id, expiresAt, token, createdAt, updatedAt, userId) VALUES ('s1', ?, 'payer-token', ?, ?, ?)`,
    new Date(Date.now() + DAY * 1000).toISOString(), iso, iso, USER,
  );
});

function subscriptionRow(status: string) {
  db.query(
    `INSERT INTO "subscription" (id, plan, referenceId, stripeCustomerId, stripeSubscriptionId, status, periodStart, periodEnd, seats)
     VALUES ('row_1', 'pro', ?, ?, 'sub_1', ?, ?, ?, 1)`,
    USER, CUSTOMER, status,
    new Date((now() - 5 * DAY) * 1000).toISOString(),
    new Date((now() + 25 * DAY) * 1000).toISOString(),
  );
}

async function deliver(event: Record<string, unknown>, opts: { timestamp?: number; tamper?: boolean } = {}) {
  const payload = JSON.stringify({ object: "event", api_version: "2026-02-25.clover", created: now(), ...event });
  const signature = Stripe.webhooks.generateTestHeaderString({
    payload,
    secret: WEBHOOK_SECRET,
    ...(opts.timestamp ? { timestamp: opts.timestamp } : {}),
  });
  return buildAuth(env).handler(
    new Request("http://localhost:8787/api/auth/stripe/webhook", {
      method: "POST",
      headers: { "stripe-signature": signature, "Content-Type": "application/json" },
      body: opts.tamper ? payload.replace('"active"', '"trialing"') : payload,
    }),
  );
}

function upgrade(body: Record<string, unknown>) {
  return buildAuth(env).handler(
    new Request("http://localhost:8787/api/auth/subscription/upgrade", {
      method: "POST",
      headers: {
        Authorization: "Bearer payer-token",
        "Content-Type": "application/json",
        Origin: "http://localhost:3200",
      },
      body: JSON.stringify({ successUrl: "/", cancelUrl: "/", ...body }),
    }),
  );
}

describe("webhook: signature over the raw body", () => {
  it("refuses a tampered body, a stale timestamp, and a missing signature", async () => {
    subscriptionRow("canceled");
    fake.subscriptions.set("sub_1", subscriptionObject("active"));
    const event = { id: "evt_1", type: "customer.subscription.updated", data: { object: subscriptionObject("active") } };
    expect((await deliver(event, { tamper: true })).status).toBe(400);
    expect((await deliver(event, { timestamp: now() - 3600 })).status).toBe(400);
    const unsigned = await buildAuth(env).handler(
      new Request("http://localhost:8787/api/auth/stripe/webhook", { method: "POST", body: JSON.stringify(event) }),
    );
    expect(unsigned.status).toBe(400);
    expect(db.query(`SELECT status FROM "subscription"`)[0]).toEqual({ status: "canceled" });
  });
});

describe("webhook: stale and out-of-order deliveries", () => {
  it("EXPLOIT: a late customer.subscription.updated cannot resurrect a cancelled subscription", async () => {
    // Stripe's truth: cancelled (e.g. refunded and cancelled immediately).
    subscriptionRow("canceled");
    fake.subscriptions.set("sub_1", subscriptionObject("canceled"));
    expect(await hasPaidSubscription(db, USER)).toBe(false);

    // An OLDER update — retried after we 429'd/5xx'd it — arrives last, still
    // saying active with the period open.
    const res = await deliver({
      id: "evt_old",
      type: "customer.subscription.updated",
      data: { object: subscriptionObject("active") },
    });
    expect(res.status).toBe(200);
    expect(db.query(`SELECT status FROM "subscription"`)[0]).toEqual({ status: "canceled" });
    expect(await hasPaidSubscription(db, USER)).toBe(false);
    // It was decided from a fresh read of the subscription.
    expect(fake.calls.some((c) => c.method === "GET" && c.path === "/v1/subscriptions/sub_1")).toBe(true);
  });

  it("a current update still applies (and a failed re-read is retried by Stripe, not applied)", async () => {
    subscriptionRow("incomplete");
    fake.subscriptions.set("sub_1", subscriptionObject("active"));
    const event = { id: "evt_new", type: "customer.subscription.updated", data: { object: subscriptionObject("active") } };
    expect((await deliver(event)).status).toBe(200);
    expect(await hasPaidSubscription(db, USER)).toBe(true);

    db.query(`UPDATE "subscription" SET status = 'incomplete'`);
    fake.subscriptions.delete("sub_1"); // Stripe unreachable / unknown → 400, Stripe redelivers
    expect((await deliver({ ...event, id: "evt_retry" })).status).toBe(400);
    expect(db.query(`SELECT status FROM "subscription"`)[0]).toEqual({ status: "incomplete" });
  });
});

describe("webhook: disputes", () => {
  it("EXPLOIT: a chargeback cancels the customer's live subscription (then the deletion revokes access)", async () => {
    subscriptionRow("active");
    fake.subscriptions.set("sub_1", subscriptionObject("active"));
    fake.charges.set("ch_1", { id: "ch_1", object: "charge", customer: CUSTOMER });
    expect(await hasPaidSubscription(db, USER)).toBe(true);

    const res = await deliver({
      id: "evt_dp",
      type: "charge.dispute.created",
      data: { object: { id: "dp_1", object: "dispute", charge: "ch_1", status: "needs_response" } },
    });
    expect(res.status).toBe(200);
    expect(fake.calls.filter((c) => c.method === "DELETE").map((c) => c.path.split("?")[0])).toEqual(["/v1/subscriptions/sub_1"]);

    // Stripe then sends the deletion, which is what flips the row.
    await deliver({ id: "evt_del", type: "customer.subscription.deleted", data: { object: subscriptionObject("canceled") } });
    expect(await hasPaidSubscription(db, USER)).toBe(false);
  });

  it("an inquiry (warning_*) moves no money and cancels nothing", async () => {
    subscriptionRow("active");
    fake.subscriptions.set("sub_1", subscriptionObject("active"));
    fake.charges.set("ch_1", { id: "ch_1", object: "charge", customer: CUSTOMER });
    await deliver({
      id: "evt_inq",
      type: "charge.dispute.created",
      data: { object: { id: "dp_2", object: "dispute", charge: "ch_1", status: "warning_needs_response" } },
    });
    expect(fake.calls.filter((c) => c.method === "DELETE")).toEqual([]);
    expect(await hasPaidSubscription(db, USER)).toBe(true);
  });
});

describe("checkout creation", () => {
  const checkouts = () => fake.calls.filter((c) => c.method === "POST" && c.path === "/v1/checkout/sessions");

  it("the price comes from server config, never the client", async () => {
    const res = await upgrade({ plan: "pro", priceId: "price_attacker_cheap", annual: false });
    expect(res.status).toBe(200);
    expect(checkouts()).toHaveLength(1);
    const body = decodeURIComponent(checkouts()[0].body);
    expect(body).toContain(`line_items[0][price]=${PRICE}`);
    expect(body).not.toContain("price_attacker_cheap");
    expect(body).toContain(`client_reference_id=${USER}`);
    // Unknown plans are refused outright.
    expect((await upgrade({ plan: "enterprise-free" })).status).toBe(400);
  });

  it("EXPLOIT: a Pro plan hidden in the admin console cannot be bought through the env-price fallback", async () => {
    // Even with the legacy secret still set, and the price still keyed.
    env.STRIPE_PRO_PRICE_ID = PRICE;
    db.query(`UPDATE plan SET is_active = 0 WHERE name = 'pro'`);
    const res = await upgrade({ plan: "pro" });
    expect(res.status).toBe(400);
    expect(checkouts()).toEqual([]);
  });

  it("quantity is pinned: a checkout is for exactly one seat", async () => {
    expect((await upgrade({ plan: "pro", seats: 50 })).status).toBe(400);
    expect((await upgrade({ plan: "pro", seats: 0 })).status).toBe(400);
    expect(checkouts()).toEqual([]);
    expect((await upgrade({ plan: "pro", seats: 1 })).status).toBe(200);
    expect(decodeURIComponent(checkouts()[0].body)).toContain("line_items[0][quantity]=1");
  });

  it("EXPLOIT: deleting the local trial history (via /subscription/cancel) does not earn a second free trial", async () => {
    db.query(`UPDATE plan SET price_id = ?, trial_days = 7 WHERE name = 'pro'`, PRICE);
    // Had a trial, cancelled it before paying anything.
    db.query(
      `INSERT INTO "subscription" (id, plan, referenceId, stripeCustomerId, stripeSubscriptionId, status, trialStart, trialEnd)
       VALUES ('row_1', 'pro', ?, ?, 'sub_1', 'canceled', ?, ?)`,
      USER, CUSTOMER, new Date(Date.now() - 20 * DAY * 1000).toISOString(), new Date(Date.now() - 13 * DAY * 1000).toISOString(),
    );
    fake.subscriptions.set("sub_1", subscriptionObject("canceled", { trial_start: now() - 20 * DAY, trial_end: now() - 13 * DAY }));

    // The plugin's cancel endpoint DELETES a row whose Stripe subscription is
    // no longer active — and with it the only record the plugin checks for
    // "already had a trial".
    const cancel = await buildAuth(env).handler(
      new Request("http://localhost:8787/api/auth/subscription/cancel", {
        method: "POST",
        headers: { Authorization: "Bearer payer-token", "Content-Type": "application/json", Origin: "http://localhost:3200" },
        body: JSON.stringify({ subscriptionId: "sub_1", returnUrl: "/" }),
      }),
    );
    expect(cancel.status).toBe(400);
    expect(db.query(`SELECT id FROM "subscription"`)).toEqual([]);

    expect((await upgrade({ plan: "pro" })).status).toBe(200);
    expect(decodeURIComponent(checkouts()[0].body)).not.toContain("trial_period_days");
  });

  it("a customer who never trialled still gets the plan's trial", async () => {
    db.query(`UPDATE plan SET price_id = ?, trial_days = 7 WHERE name = 'pro'`, PRICE);
    expect((await upgrade({ plan: "pro" })).status).toBe(200);
    expect(decodeURIComponent(checkouts()[0].body)).toContain("subscription_data[trial_period_days]=7");
  });

  it("another user's subscription or reference cannot be targeted", async () => {
    const iso = new Date().toISOString();
    db.query(
      `INSERT INTO "subscription" (id, plan, referenceId, stripeCustomerId, stripeSubscriptionId, status)
       VALUES ('row_other', 'pro', 'someone-else', 'cus_other', 'sub_other', 'active')`,
    );
    void iso;
    expect((await upgrade({ plan: "pro", referenceId: "someone-else" })).status).toBe(400);
    expect((await upgrade({ plan: "pro", subscriptionId: "sub_other" })).status).toBe(400);
    expect((await upgrade({ plan: "pro", customerType: "organization", referenceId: "org1" })).status).toBe(400);
    expect(checkouts()).toEqual([]);
  });
});

describe("checkout without hard-coded prices", () => {
  const checkouts = () => fake.calls.filter((c) => c.method === "POST" && c.path === "/v1/checkout/sessions");
  const lookups = () => fake.calls.filter((c) => c.method === "GET" && c.path.startsWith("/v1/prices?"));

  it("sells the plan table's price with the env price secrets absent", async () => {
    expect(env.STRIPE_PRO_PRICE_ID).toBeUndefined();
    expect(env.STRIPE_PRO_ANNUAL_PRICE_ID).toBeUndefined();
    expect((await upgrade({ plan: "pro" })).status).toBe(200);
    expect(decodeURIComponent(checkouts()[0].body)).toContain(`line_items[0][price]=${PRICE}`);
    // A stored price needs no lookup.
    expect(lookups().some((c) => decodeURIComponent(c.path).includes("capturecat_pro_monthly"))).toBe(false);
  });

  it("a sellable row with no stored price is sold at the price holding its lookup key", async () => {
    db.query(`UPDATE plan SET price_id = NULL WHERE name = 'pro'`);
    expect((await upgrade({ plan: "pro" })).status).toBe(200);
    expect(decodeURIComponent(checkouts()[0].body)).toContain(`line_items[0][price]=${PRICE}`);
    expect(lookups().some((c) => decodeURIComponent(c.path).includes("lookup_keys[0]=capturecat_pro_monthly"))).toBe(true);
  });

  it("the legacy env price is never sold: no stored and no keyed price refuses checkout", async () => {
    env.STRIPE_PRO_PRICE_ID = "price_env_legacy";
    db.query(`UPDATE plan SET price_id = NULL WHERE name = 'pro'`);
    catalog.prices.get(PRICE)!.lookup_key = null;
    expect((await upgrade({ plan: "pro" })).status).toBe(400);
    expect(checkouts()).toEqual([]);
  });

  it("EXPLOIT: a hidden plan stays unsellable even when its lookup key resolves", async () => {
    db.query(`UPDATE plan SET is_active = 0, price_id = NULL WHERE name = 'pro'`);
    expect((await upgrade({ plan: "pro" })).status).toBe(400);
    expect(checkouts()).toEqual([]);
  });
});

describe("hiding a plan stops new sales only", () => {
  const checkouts = () => fake.calls.filter((c) => c.method === "POST" && c.path === "/v1/checkout/sessions");

  it("current subscribers keep the hidden plan's features until the subscription ends; checkout is refused", async () => {
    const pro = await planForEntitlement(db, { tier: "paid", planName: "pro" });
    expect(pro.features.cloudShare).toBe(true);

    for (const status of ["active", "trialing", "past_due"]) {
      db.query(`DELETE FROM "subscription"`);
      db.query(`UPDATE plan SET is_active = 1 WHERE name = 'pro'`);
      subscriptionRow(status);
      db.query(`UPDATE plan SET is_active = 0 WHERE name = 'pro'`);

      const ent = await resolveEntitlement(db, USER, { tester: false, blocked: false });
      expect(ent).toEqual({ tier: "paid", planName: "pro" });
      const plan = await planForEntitlement(db, ent as Exclude<typeof ent, "blocked">);
      expect(plan.name).toBe("pro");
      expect(plan.features).toEqual(pro.features);
      expect(plan.limits).toEqual(pro.limits);
    }

    // Nobody new can buy it.
    expect((await upgrade({ plan: "pro" })).status).toBe(400);
    expect(checkouts()).toEqual([]);

    // When the subscription ends, so does access.
    db.query(`UPDATE "subscription" SET status = 'canceled'`);
    const after = await resolveEntitlement(db, USER, { tester: false, blocked: false });
    expect((await planForEntitlement(db, after as Exclude<typeof after, "blocked">)).name).toBe("free");
  });

  it("a subscription naming a plan that no longer exists still gets nothing", async () => {
    expect((await planForEntitlement(db, { tier: "paid", planName: "deleted-tier" })).name).toBe("free");
  });
});

describe("sales at checkout", () => {
  const checkouts = () => fake.calls.filter((c) => c.method === "POST" && c.path === "/v1/checkout/sessions");
  const lastCheckout = () => decodeURIComponent(checkouts().at(-1)!.body);
  const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();
  const HOUR = 3_600_000;

  function sale(opts: { start?: string | null; end: string; monthlyCoupon?: string | null; annual?: boolean }) {
    db.query(
      `UPDATE plan SET sale_label = 'Launch price', sale_price_monthly_cents = 700, sale_starts_at = ?, sale_ends_at = ?,
                       stripe_sale_coupon_id = ? WHERE name = 'pro'`,
      opts.start ?? null, opts.end, opts.monthlyCoupon === undefined ? "coupon_m" : opts.monthlyCoupon,
    );
    if (opts.annual) {
      catalog.addPrice({ id: "price_pro_yearly", product: PRODUCT, unit_amount: 10000, interval: "year", lookup_key: "capturecat_pro_yearly" });
      db.query(
        `UPDATE plan SET annual_price_id = 'price_pro_yearly', annual_amount_cents = 10000,
                         sale_price_annual_cents = 7000, stripe_sale_annual_coupon_id = 'coupon_y' WHERE name = 'pro'`,
      );
    }
  }

  it("inside the window: the interval's coupon is applied and the session expires by the sale's end", async () => {
    const end = iso(2 * HOUR);
    sale({ end });
    expect((await upgrade({ plan: "pro" })).status).toBe(200);
    expect(lastCheckout()).toContain("discounts[0][coupon]=coupon_m");
    expect(lastCheckout()).toContain(`expires_at=${Math.floor(Date.parse(end) / 1000)}`);
    // Still the REGULAR price: the coupon is the discount.
    expect(lastCheckout()).toContain(`line_items[0][price]=${PRICE}`);
  });

  it("a sale ending within 30 minutes still leaves Stripe's minimum session lifetime", async () => {
    sale({ end: iso(10 * 60_000) });
    const before = Math.floor(Date.now() / 1000);
    expect((await upgrade({ plan: "pro" })).status).toBe(200);
    const expires = Number(/expires_at=(\d+)/.exec(lastCheckout())![1]);
    expect(expires).toBeGreaterThanOrEqual(before + 31 * 60);
    expect(expires).toBeLessThanOrEqual(before + 31 * 60 + 5);
  });

  it("an annual checkout gets the annual coupon", async () => {
    sale({ end: iso(48 * HOUR), annual: true });
    expect((await upgrade({ plan: "pro", annual: true })).status).toBe(200);
    expect(lastCheckout()).toContain("line_items[0][price]=price_pro_yearly");
    expect(lastCheckout()).toContain("discounts[0][coupon]=coupon_y");
    // A sale 48h out is capped at Stripe's 24h maximum.
    const expires = Number(/expires_at=(\d+)/.exec(lastCheckout())![1]);
    expect(expires).toBeLessThanOrEqual(Math.floor(Date.now() / 1000) + 24 * 3600);
  });

  it("outside the window — not started, or over — no coupon and Stripe's default expiry", async () => {
    sale({ start: iso(HOUR), end: iso(5 * HOUR) });
    expect((await upgrade({ plan: "pro" })).status).toBe(200);
    expect(lastCheckout()).not.toContain("discounts");
    expect(lastCheckout()).not.toContain("expires_at");

    sale({ start: iso(-5 * HOUR), end: iso(-HOUR) });
    expect((await upgrade({ plan: "pro" })).status).toBe(200);
    expect(lastCheckout()).not.toContain("discounts");
  });

  it("a sale without its Stripe coupon is not applied", async () => {
    sale({ end: iso(2 * HOUR), monthlyCoupon: null });
    expect((await upgrade({ plan: "pro" })).status).toBe(200);
    expect(lastCheckout()).not.toContain("discounts");
  });

  it("the sale and the plan's trial combine", async () => {
    db.query(`UPDATE plan SET trial_days = 7 WHERE name = 'pro'`);
    sale({ end: iso(2 * HOUR) });
    expect((await upgrade({ plan: "pro" })).status).toBe(200);
    expect(lastCheckout()).toContain("discounts[0][coupon]=coupon_m");
    expect(lastCheckout()).toContain("subscription_data[trial_period_days]=7");
  });
});

describe("webhook: catalog events (Stripe Dashboard → plan table)", () => {
  const proRow = () =>
    db.query(
      `SELECT display_name, description, price_id, annual_price_id, monthly_amount_cents, annual_amount_cents, currency,
              is_active, features, limits FROM plan WHERE name = 'pro'`,
    )[0] as Record<string, unknown>;
  let seq = 0;
  const catalogEvent = (type: string, object: Record<string, unknown>) =>
    deliver({ id: `evt_catalog_${++seq}`, type, data: { object } });

  it("a price changed in the Dashboard (new keyed price, old archived) updates the plan — from a fresh read", async () => {
    // What the Dashboard does: a new price with the key transferred, the old archived.
    catalog.prices.get(PRICE)!.lookup_key = null;
    catalog.prices.get(PRICE)!.active = false;
    catalog.addPrice({ id: "price_pro_v2", product: PRODUCT, unit_amount: 1200, lookup_key: "capturecat_pro_monthly" });

    // The event carries a stale/forged amount; the re-read wins.
    const res = await catalogEvent("price.created", { id: "price_pro_v2", object: "price", unit_amount: 1, active: true });
    expect(res.status).toBe(200);
    expect(proRow()).toMatchObject({ price_id: "price_pro_v2", monthly_amount_cents: 1200 });

    // A late, stale update for the OLD price (still claiming the key) changes nothing.
    await catalogEvent("price.updated", { id: PRICE, object: "price", active: true, lookup_key: "capturecat_pro_monthly", unit_amount: 1000 });
    expect(proRow()).toMatchObject({ price_id: "price_pro_v2", monthly_amount_cents: 1200 });
  });

  it("product.updated renames the plan but never activates it or touches its features and limits", async () => {
    db.query(`UPDATE plan SET is_active = 0 WHERE name = 'pro'`);
    const before = proRow();
    const product = catalog.products.get(PRODUCT)!;
    product.name = "CaptureCat Pro+";
    product.description = "Everything, and more.";
    const res = await catalogEvent("product.updated", { id: PRODUCT, object: "product", name: "stale" });
    expect(res.status).toBe(200);
    expect(proRow()).toEqual({ ...before, display_name: "CaptureCat Pro+", description: "Everything, and more." });
  });

  it("ignores products and prices that are not a plan's", async () => {
    const before = proRow();
    catalog.addProduct({ id: "prod_other", name: "Some other thing" });
    catalog.addProduct({ id: "prod_dupe", name: "Old duplicate", metadata: { plan: "pro" } });
    catalog.addPrice({ id: "price_other", product: "prod_other", unit_amount: 5 });
    catalog.addPrice({ id: "price_unkeyed", product: PRODUCT, unit_amount: 1 });
    for (const [type, id] of [
      ["product.updated", "prod_other"],
      ["product.updated", "prod_dupe"],
      ["price.created", "price_other"],
      ["price.created", "price_unkeyed"],
    ] as const) {
      const res = await catalogEvent(type, { id, object: type.split(".")[0] });
      expect(res.status).toBe(200);
    }
    expect(proRow()).toEqual(before);
  });

  it("deleting or archiving an interval's only price stops that interval being sold", async () => {
    catalog.addPrice({ id: "price_pro_yearly", product: PRODUCT, unit_amount: 10000, interval: "year", lookup_key: "capturecat_pro_yearly" });
    db.query(`UPDATE plan SET annual_price_id = 'price_pro_yearly', annual_amount_cents = 10000 WHERE name = 'pro'`);
    catalog.prices.delete("price_pro_yearly");
    const res = await catalogEvent("price.deleted", { id: "price_pro_yearly", object: "price", lookup_key: "capturecat_pro_yearly" });
    expect(res.status).toBe(200);
    expect(proRow()).toMatchObject({ annual_price_id: null, annual_amount_cents: null, price_id: PRICE });
  });

  it("refuses a tampered catalog event", async () => {
    const before = proRow();
    catalog.addPrice({ id: "price_pro_v2", product: PRODUCT, unit_amount: 1, lookup_key: "capturecat_pro_monthly" });
    const res = await deliver(
      { id: "evt_t", type: "price.created", data: { object: { id: "price_pro_v2", object: "price", active: true } } },
      { tamper: true },
    );
    expect(res.status).toBe(400);
    expect(proRow()).toEqual(before);
  });
});

describe("a saved Stripe customer this key does not know", () => {
  const checkouts = () => fake.calls.filter((c) => c.method === "POST" && c.path === "/v1/checkout/sessions");
  const savedCustomer = () =>
    db.query<{ stripeCustomerId: string | null }>(`SELECT stripeCustomerId FROM "user" WHERE id = ?`, USER)[0]?.stripeCustomerId;

  it("is replaced at checkout instead of failing every time (No such customer)", async () => {
    // Prod, 2026-10-01: an account made under an earlier key kept cus_… that
    // the live key has never seen; every upgrade was a 500.
    fake.missingCustomers.add(CUSTOMER);
    const res = await upgrade({ plan: "pro" });
    expect(res.status).toBe(200);
    expect(savedCustomer()).toBe("cus_new_1");
    expect(decodeURIComponent(checkouts()[0].body)).toContain("customer=cus_new_1");
  });

  it("a customer that exists is never replaced", async () => {
    const res = await upgrade({ plan: "pro" });
    expect(res.status).toBe(200);
    expect(savedCustomer()).toBe(CUSTOMER);
    expect(fake.calls.some((c) => c.method === "POST" && c.path === "/v1/customers")).toBe(false);
  });

  it("an unknown Stripe failure leaves the saved customer alone", async () => {
    // Not resource_missing (e.g. Stripe down): nothing is cleared.
    fake.missingCustomers.clear();
    const realFetch = globalThis.fetch;
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
      if (/^\/v1\/customers\/[^/]+$/.test(url.pathname)) return json({ error: { type: "api_error", message: "boom" } }, 500);
      return realFetch(input, init);
    }));
    try {
      await upgrade({ plan: "pro" });
      expect(savedCustomer()).toBe(CUSTOMER);
    } finally {
      vi.stubGlobal("fetch", realFetch);
    }
  });
});
