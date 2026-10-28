/**
 * "Assign plan" through the REAL admin routes (requireAuth + the admin role
 * gate), the real migrations (node:sqlite) and the real `stripe` SDK talking
 * to the in-memory Stripe behind a stubbed `fetch`. Nothing reaches Stripe.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { FakeStripeCatalog } from "../test-support/fake-stripe-catalog";
import { clearLookupKeyCache } from "../lib/stripe-catalog";
import { activeSubscriptionPlan, hasPaidSubscription } from "../lib/stripe";

vi.mock("../lib/auth", () => import("../test-support/fake-session"));
vi.stubGlobal("caches", {
  default: { match: async () => undefined, put: async () => undefined, delete: async () => true },
});

const catalog = new FakeStripeCatalog({ billing: true });
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

const ADMIN = "admin-user";
const USER = "user-1";
const DAY = 86_400_000;
let db: TestD1;
let env: Env;
let app: Hono<{ Bindings: Env; Variables: Variables }>;

function addUser(id: string, email: string, role = "user", stripeCustomerId: string | null = null) {
  const iso = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked, role, stripeCustomerId)
     VALUES (?, ?, ?, 1, ?, ?, 0, 0, ?, ?)`,
    id, email.split("@")[0], email, iso, iso, role, stripeCustomerId,
  );
}

beforeEach(async () => {
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
  addUser(ADMIN, "admin@test.local", "admin");
  addUser(USER, "someone@test.local");
  app = new Hono<{ Bindings: Env; Variables: Variables }>();
  app.route("/api", adminRoutes);
  // Two sellable plans, provisioned through the real editor (product + keyed prices).
  for (const [name, cents] of [["team", 2900], ["studio", 4900]] as const) {
    await ok(call("POST", "/admin/plans", { name, displayName: `CaptureCat ${name}`, monthlyCents: cents, annualCents: cents * 10 }), 201);
  }
  calls.length = 0;
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

const subRows = (uid = USER) =>
  db.query(`SELECT * FROM "subscription" WHERE "referenceId" = ? ORDER BY "periodStart"`, uid) as Record<string, any>[];
const grants = (uid = USER) => db.query(`SELECT * FROM plan_grants WHERE user_id = ? ORDER BY granted_at`, uid) as Record<string, any>[];
const stripeWrites = () => calls.filter((c) => c.method !== "GET");

describe("assign a plan", () => {
  it("creates a complimentary Stripe subscription and the user is on the plan at once", async () => {
    const res = await ok(call("POST", `/admin/users/${USER}/plan`, { plan: "Team" }));
    expect(res).toMatchObject({ plan: "team", source: "grant", status: "active", until: null });

    // Stripe: a customer for the user, the 100%-off forever coupon, a subscription on the team monthly price.
    const customers = [...catalog.customers.values()];
    expect(customers).toHaveLength(1);
    expect(customers[0]).toMatchObject({ email: "someone@test.local", metadata: { userId: USER } });
    expect(catalog.coupons.get("capturecat_complimentary")).toMatchObject({ percent_off: 100, duration: "forever" });
    const [sub] = [...catalog.subscriptions.values()];
    expect(sub.items.data[0].price.lookup_key).toBe("capturecat_team_monthly");
    expect(sub.discounts).toEqual(["capturecat_complimentary"]);
    expect(sub.metadata).toMatchObject({ userId: USER, referenceId: USER, grantedBy: ADMIN });

    // D1: the plugin-shaped row (its id on the Stripe object, so webhooks find it), the grant, the customer id.
    const [row] = subRows();
    expect(row).toMatchObject({ plan: "team", status: "active", stripeSubscriptionId: sub.id, billingInterval: "month" });
    expect(sub.metadata.subscriptionId).toBe(row.id);
    expect(grants()).toMatchObject([{ plan: "team", stripe_subscription_id: sub.id, granted_by: ADMIN, revoked_at: null }]);
    expect(db.query(`SELECT stripeCustomerId FROM "user" WHERE id = ?`, USER)[0]).toEqual({ stripeCustomerId: customers[0].id });

    // What the entitlement path reads.
    expect(await hasPaidSubscription(db, USER)).toBe(true);
    expect(await activeSubscriptionPlan(db, USER)).toBe("team");
    expect(await ok(call("GET", `/admin/users/${USER}/plan`))).toMatchObject({
      plan: "team",
      source: "grant",
      grant: { plan: "team", grantedBy: "admin@test.local", until: null },
    });
    const listed = (await ok(call("GET", "/admin/users"))).users.find((u: any) => u.id === USER);
    expect(listed).toMatchObject({ paid: true, plan: "team", planGranted: true });
  });

  it("switching plans ends the old grant only after the new one exists; the coupon is reused", async () => {
    await ok(call("POST", `/admin/users/${USER}/plan`, { plan: "team" }));
    const [first] = [...catalog.subscriptions.values()];
    await ok(call("POST", `/admin/users/${USER}/plan`, { plan: "studio" }));

    expect(catalog.subscriptions.get(first.id)!.status).toBe("canceled");
    expect(calls.filter((c) => c.method === "POST" && c.path === "/v1/coupons")).toHaveLength(1);
    expect(catalog.customers.size).toBe(1); // the stored customer is reused
    const rows = subRows();
    expect(rows.map((r) => [r.plan, r.status])).toEqual([["team", "canceled"], ["studio", "active"]]);
    const g = grants();
    expect(g[0].revoked_at).not.toBeNull();
    expect(g[0].revoked_by).toBe(ADMIN);
    expect(g[1]).toMatchObject({ plan: "studio", revoked_at: null });
    expect(await activeSubscriptionPlan(db, USER)).toBe("studio");
  });

  it('"free" removes the grant: Stripe cancels, the user is free again', async () => {
    await ok(call("POST", `/admin/users/${USER}/plan`, { plan: "team" }));
    expect(await ok(call("POST", `/admin/users/${USER}/plan`, { plan: "free" }))).toMatchObject({ plan: "free", removed: 1 });
    expect([...catalog.subscriptions.values()][0].status).toBe("canceled");
    expect(subRows()[0].status).toBe("canceled");
    expect(await hasPaidSubscription(db, USER)).toBe(false);
    expect(await ok(call("GET", `/admin/users/${USER}/plan`))).toMatchObject({ plan: "free", source: "none", grant: null });
  });

  it("an end date becomes Stripe's cancel_at and is kept on the grant", async () => {
    const until = new Date(Date.now() + 30 * DAY).toISOString().slice(0, 10);
    const res = await ok(call("POST", `/admin/users/${USER}/plan`, { plan: "team", until }));
    const [sub] = [...catalog.subscriptions.values()];
    expect(sub.cancel_at).toBe(Math.floor(new Date(`${until}T23:59:59Z`).getTime() / 1000));
    expect(res.until).toBe(`${until}T23:59:59.000Z`);
    expect(grants()[0].until).toBe(`${until}T23:59:59.000Z`);
    expect(subRows()[0].cancelAt).toBe(`${until}T23:59:59.000Z`);
  });

  it("never touches a customer who pays: 409 and no Stripe writes", async () => {
    db.query(
      `INSERT INTO "subscription" ("id", "plan", "referenceId", "stripeSubscriptionId", "status", "periodEnd")
       VALUES ('paid-row', 'team', ?, 'sub_customer_pays', 'active', ?)`,
      USER, new Date(Date.now() + 10 * DAY).toISOString(),
    );
    const r = await call("POST", `/admin/users/${USER}/plan`, { plan: "studio" });
    expect(r.status).toBe(409);
    expect(((await r.json()) as { error: string }).error).toMatch(/team subscription in Stripe/);
    expect(stripeWrites()).toEqual([]);
    expect(await ok(call("GET", `/admin/users/${USER}/plan`))).toMatchObject({ plan: "team", source: "stripe", grant: null });
  });

  it("replaces a customer id Stripe no longer has", async () => {
    db.query(`UPDATE "user" SET stripeCustomerId = 'cus_gone' WHERE id = ?`, USER);
    await ok(call("POST", `/admin/users/${USER}/plan`, { plan: "team" }));
    const [customer] = [...catalog.customers.values()];
    expect(db.query(`SELECT stripeCustomerId FROM "user" WHERE id = ?`, USER)[0]).toEqual({ stripeCustomerId: customer.id });
  });

  it("a subscription Stripe does not activate is undone and nothing is written", async () => {
    catalog.nextSubscriptionStatus = "incomplete";
    const r = await call("POST", `/admin/users/${USER}/plan`, { plan: "team" });
    expect(r.status).toBe(502);
    expect([...catalog.subscriptions.values()][0].status).toBe("canceled");
    expect(subRows()).toEqual([]);
    expect(grants()).toEqual([]);
  });

  it("rejects bad input and hides itself from non-admins", async () => {
    expect((await call("POST", `/admin/users/${USER}/plan`, { plan: "nope" })).status).toBe(400);
    expect((await call("POST", `/admin/users/${USER}/plan`, { plan: "team", until: "2001-01-01" })).status).toBe(400);
    expect((await call("POST", `/admin/users/${USER}/plan`, { plan: "team", extra: 1 })).status).toBe(400);
    expect((await call("POST", `/admin/users/nobody/plan`, { plan: "team" })).status).toBe(404);
    expect((await call("POST", `/admin/users/${USER}/plan`, { plan: "team" }, USER)).status).toBe(404);
    expect((await call("GET", `/admin/users/${USER}/plan`, undefined, USER)).status).toBe(404);
    expect(stripeWrites()).toEqual([]);
  });
});
