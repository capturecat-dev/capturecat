/**
 * The Worker's outer middleware (src/index.ts): per-IP limiters in front of
 * Better Auth. The Cache API the limiter counts in is an in-memory Map here,
 * and the auth handler never reaches Stripe (unsigned deliveries are refused
 * at the signature check).
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "./types";
import { createTestD1 } from "./test-support/d1-sqlite.js";

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));

const store = new Map<string, string>();
vi.stubGlobal("caches", {
  default: {
    match: async (req: Request) => {
      const hit = store.get(req.url);
      return hit === undefined ? undefined : new Response(hit);
    },
    put: async (req: Request, res: Response) => {
      store.set(req.url, await res.text());
    },
    delete: async (req: Request) => store.delete(req.url),
  },
});
vi.stubGlobal(
  "fetch",
  vi.fn(async () => new Response(JSON.stringify({ error: { message: "offline test" } }), { status: 500 })),
);

const { default: worker } = await import("./index");

let env: Env;
beforeEach(() => {
  store.clear();
  env = {
    DB: createTestD1(),
    BETTER_AUTH_URL: "http://localhost:8787",
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
    GOOGLE_CLIENT_ID: "google-test",
    GOOGLE_CLIENT_SECRET: "google-test-secret",
    STRIPE_SECRET_KEY: "sk_test_offline",
    STRIPE_WEBHOOK_SECRET: "whsec_offline",
    STRIPE_PRO_PRICE_ID: "price_pro_monthly",
  } as unknown as Env;
});

const STRIPE_IP = "3.18.12.63"; // one of Stripe's webhook egress IPs

function post(path: string) {
  return worker.fetch(
    new Request(`http://localhost:8787${path}`, {
      method: "POST",
      headers: { "CF-Connecting-IP": STRIPE_IP, "stripe-signature": "t=1,v1=bad", "Content-Type": "application/json" },
      body: "{}",
    }),
    env,
    { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext,
  );
}

describe("Stripe webhook vs the per-IP auth limiter", () => {
  it("EXPLOIT: webhook deliveries are never 429'd by the sign-in limiter (a throttled cancellation is a late one)", async () => {
    // Stripe delivers every merchant's events from a handful of IPs. The
    // 30/min credential limiter keyed on that IP turned a burst of events —
    // which any customer can cause by toggling their subscription in the
    // portal — into 429s, and Stripe retries 429s later and OUT OF ORDER.
    const statuses: number[] = [];
    for (let i = 0; i < 40; i++) statuses.push((await post("/api/auth/stripe/webhook")).status);
    expect(statuses.filter((s) => s === 429)).toEqual([]);
    expect(new Set(statuses)).toEqual(new Set([400])); // refused at the signature check, every time
  });

  it("credential endpoints from one IP are still limited", async () => {
    const statuses: number[] = [];
    for (let i = 0; i < 31; i++) statuses.push((await post("/api/auth/sign-in/social")).status);
    expect(statuses.at(-1)).toBe(429);
  });
});
