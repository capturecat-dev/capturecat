/**
 * The REAL Better Auth instance (buildAuth) against the real migrations
 * (node:sqlite via test-support/d1-sqlite.js). What is faked: `fetch`, so any
 * Stripe API call the plugin makes is recorded and answered locally — nothing
 * here can reach Stripe or Cloudflare.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import { parseUserInput } from "better-auth/db";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { buildAuth } from "./auth";

const stripeCalls = vi.hoisted(() => [] as Array<{ method: string; url: string; body: string }>);

vi.stubGlobal(
  "fetch",
  vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    stripeCalls.push({ method: init?.method ?? "GET", url, body: String(init?.body ?? "") });
    // The customer the attacker pointed at exists, with the VICTIM's email;
    // the attacker's own customer answers too (the plugin re-reads it on
    // every user update to sync the email).
    const customer = /\/v1\/customers\/(cus_victim|cus_attacker)/.exec(url)?.[1];
    if (customer) {
      const email = customer === "cus_victim" ? "victim@test.local" : "attacker@test.local";
      return new Response(JSON.stringify({ id: customer, object: "customer", email, metadata: {} }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    return new Response(JSON.stringify({ error: { message: "offline test" } }), { status: 500 });
  }),
);

const ORIGIN = "http://localhost:3200";
let db: TestD1;
let env: Env;

beforeEach(() => {
  stripeCalls.length = 0;
  db = createTestD1();
  env = {
    DB: db,
    BETTER_AUTH_URL: "http://localhost:8787",
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
    GOOGLE_CLIENT_ID: "google-test",
    GOOGLE_CLIENT_SECRET: "google-test-secret",
    STRIPE_SECRET_KEY: "sk_test_offline",
    STRIPE_WEBHOOK_SECRET: "whsec_offline",
    STRIPE_PRO_PRICE_ID: "price_pro_monthly",
  } as unknown as Env;
  const now = new Date().toISOString();
  const later = new Date(Date.now() + 86_400_000).toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, stripeCustomerId, tester, blocked)
     VALUES ('attacker', 'Attacker', 'attacker@test.local', 1, ?, ?, 'cus_attacker', 0, 0)`,
    now, now,
  );
  db.query(
    `INSERT INTO "session" (id, expiresAt, token, createdAt, updatedAt, userId)
     VALUES ('s1', ?, 'attacker-token', ?, ?, 'attacker')`,
    later, now, now,
  );
});

function updateUser(body: Record<string, unknown>) {
  return buildAuth(env).handler(
    new Request("http://localhost:8787/api/auth/update-user", {
      method: "POST",
      headers: { Authorization: "Bearer attacker-token", "Content-Type": "application/json", Origin: ORIGIN },
      body: JSON.stringify(body),
    }),
  );
}

describe("client-settable user fields", () => {
  it("update-user cannot re-point the caller's Stripe customer at someone else's", async () => {
    // EXPLOIT: with `stripeCustomerId` client-settable, the attacker binds
    // their account to the victim's Stripe customer. Checkout then runs on
    // the victim's customer (saved cards shown), the billing portal opens the
    // victim's billing, a dashboard-created comp for the victim maps to the
    // attacker, and the plugin's update hook rewrites the victim customer's
    // email to the attacker's.
    const res = await updateUser({ stripeCustomerId: "cus_victim" });
    expect(res.status).toBe(400);
    expect(db.query(`SELECT stripeCustomerId FROM "user" WHERE id = 'attacker'`)[0]).toEqual({
      stripeCustomerId: "cus_attacker",
    });
    // …and nothing was written to the victim's Stripe customer.
    expect(stripeCalls.filter((c) => c.url.includes("cus_victim"))).toEqual([]);
  });

  it("server-owned flags stay unsettable, and name still updates", async () => {
    for (const field of ["tester", "blocked", "role", "banned", "stripeCustomerId"]) {
      expect((await updateUser({ [field]: field === "role" ? "admin" : true })).status, field).toBe(400);
    }
    const ok = await updateUser({ name: "Renamed" });
    expect(ok.status).toBe(200);
    expect(db.query(`SELECT name, role, tester FROM "user" WHERE id = 'attacker'`)[0]).toEqual({
      name: "Renamed",
      role: null,
      tester: 0,
    });
  });

  it("every plugin/additional user field is input:false (a new plugin field must opt in deliberately)", () => {
    const auth = buildAuth(env);
    // parseUserInput is what update-user and sign-up run the body through.
    const probe = Object.fromEntries(
      ["stripeCustomerId", "tester", "blocked", "role", "banned", "banReason", "banExpires"].map((k) => [k, "x"]),
    );
    for (const [k, v] of Object.entries(probe)) {
      expect(() => parseUserInput(auth.options, { [k]: v }, "update"), k).toThrow();
    }
  });
});
