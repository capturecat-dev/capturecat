/**
 * The App Review sign-in against the REAL Better Auth instance and migrations.
 * `fetch` is stubbed so a Stripe customer-on-sign-up call stays local.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { buildAuth } from "./auth";

vi.stubGlobal(
  "fetch",
  vi.fn(async () => new Response(JSON.stringify({ error: { message: "offline test" } }), { status: 500 })),
);

const ORIGIN = "http://localhost:3200";
const EMAIL = "review@capturecat.so";
const PASSWORD = "correct-horse-battery-staple-42";
let db: TestD1;

function makeEnv(extra: Partial<Env> = {}): Env {
  return {
    DB: db,
    BETTER_AUTH_URL: "http://localhost:8787",
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
    GOOGLE_CLIENT_ID: "google-test",
    GOOGLE_CLIENT_SECRET: "google-test-secret",
    STRIPE_SECRET_KEY: "sk_test_offline",
    STRIPE_WEBHOOK_SECRET: "whsec_offline",
    STRIPE_PRO_PRICE_ID: "price_pro_monthly",
    REVIEW_LOGIN_EMAIL: EMAIL,
    REVIEW_LOGIN_PASSWORD: PASSWORD,
    ...extra,
  } as unknown as Env;
}

function signIn(env: Env, body: Record<string, unknown>) {
  return buildAuth(env).handler(
    new Request("http://localhost:8787/api/auth/review/sign-in", {
      method: "POST",
      headers: { "Content-Type": "application/json", Origin: ORIGIN },
      body: JSON.stringify(body),
    }),
  );
}

function userCount(email: string): number {
  return (db.query(`SELECT COUNT(*) AS n FROM "user" WHERE email = ?`, email) as Array<{ n: number }>)[0].n;
}

beforeEach(() => {
  db = createTestD1();
});

describe("review sign-in", () => {
  it("signs the allowlisted account in with a session cookie, creating it once", async () => {
    const env = makeEnv();
    const first = await signIn(env, { email: "  Review@CaptureCat.so ", password: PASSWORD });
    expect(first.status).toBe(200);
    expect(first.headers.get("set-cookie") ?? "").toMatch(/session_token=/);
    const second = await signIn(env, { email: EMAIL, password: PASSWORD });
    expect(second.status).toBe(200);
    expect(userCount(EMAIL)).toBe(1);

    // The cookie is a real session: get-session resolves the review user.
    const cookie = (second.headers.get("set-cookie") ?? "").split(";")[0];
    const me = await buildAuth(env).handler(
      new Request("http://localhost:8787/api/auth/get-session", { headers: { Cookie: cookie, Origin: ORIGIN } }),
    );
    expect(((await me.json()) as { user?: { email?: string } }).user?.email).toBe(EMAIL);
  });

  it("refuses a wrong password and any other email the same way, creating nothing", async () => {
    const env = makeEnv();
    const wrongPassword = await signIn(env, { email: EMAIL, password: PASSWORD + "x" });
    const otherEmail = await signIn(env, { email: "someone@else.com", password: PASSWORD });
    for (const res of [wrongPassword, otherEmail]) {
      expect(res.status).toBe(401);
      expect(res.headers.get("set-cookie") ?? "").not.toMatch(/session_token=/);
    }
    expect(userCount(EMAIL)).toBe(0);
    expect(userCount("someone@else.com")).toBe(0);
  });

  it("is off (404) without both secrets or with a short password", async () => {
    for (const extra of [
      { REVIEW_LOGIN_PASSWORD: undefined },
      { REVIEW_LOGIN_EMAIL: undefined },
      { REVIEW_LOGIN_PASSWORD: "short-password" },
    ] as Array<Partial<Env>>) {
      const env = makeEnv(extra);
      const res = await signIn(env, { email: EMAIL, password: env.REVIEW_LOGIN_PASSWORD ?? "" });
      expect(res.status).toBe(404);
    }
    expect(userCount(EMAIL)).toBe(0);
  });

  it("refuses a blocked review account", async () => {
    const now = new Date().toISOString();
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked)
       VALUES ('rev', 'App Review', ?, 1, ?, ?, 0, 1)`,
      EMAIL, now, now,
    );
    const res = await signIn(makeEnv(), { email: EMAIL, password: PASSWORD });
    expect(res.status).toBe(403);
  });
});
