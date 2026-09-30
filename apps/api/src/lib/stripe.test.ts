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
import { buildAuth } from "./auth";
import { hasPaidSubscription } from "./stripe";

const WEBHOOK_SECRET = "whsec_offline_test_secret";
const PRICE = "price_pro_monthly";
const USER = "payer";
const CUSTOMER = "cus_payer";

/** The fake Stripe account: subscriptions + charges, and every call made. */
const fake = vi.hoisted(() => ({
  subscriptions: new Map<string, Record<string, unknown>>(),
  charges: new Map<string, Record<string, unknown>>(),
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
    if ((m = /^\/v1\/prices\/([^/]+)$/.exec(p))) {
      return json({ id: m[1], object: "price", recurring: { interval: "month", usage_type: "licensed" } });
    }
    if (p === "/v1/checkout/sessions" && method === "POST") {
      return json({ id: "cs_test_1", object: "checkout.session", url: "https://checkout.stripe.test/cs_test_1" });
    }
    if ((m = /^\/v1\/customers\/([^/]+)$/.exec(p))) {
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
  fake.calls.length = 0;
  db = createTestD1();
  env = {
    DB: db,
    BETTER_AUTH_URL: "http://localhost:8787",
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
    GOOGLE_CLIENT_ID: "google-test",
    GOOGLE_CLIENT_SECRET: "google-test-secret",
    STRIPE_SECRET_KEY: "sk_test_offline",
    STRIPE_WEBHOOK_SECRET: WEBHOOK_SECRET,
    STRIPE_PRO_PRICE_ID: PRICE,
  } as unknown as Env;
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
