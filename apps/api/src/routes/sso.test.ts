/**
 * POST /api/sso/providers/:providerId/verify — our DNS-over-HTTPS copy of the
 * plugin's domain check.
 *
 * Real: the Hono router, requireAuth, requireEntitlement, every migration and
 * every SQL statement (node:sqlite via test-support/d1-sqlite.js).
 * Mocked: the Better Auth session store (bearer token = uid) and `fetch`,
 * which plays Cloudflare DoH — and, for the race, changes the provider row
 * WHILE the lookup is in flight, exactly as a concurrent
 * /api/auth/sso/update-provider would.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";

vi.mock("../lib/auth", () => import("../test-support/fake-session"));
// requireEntitlement caches plan lookups in the Workers Cache API; always miss.
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined } });

const dns = vi.hoisted(() => ({
  answers: new Map<string, string[]>(),
  duringLookup: null as null | (() => void),
}));
vi.stubGlobal(
  "fetch",
  vi.fn(async (input: RequestInfo | URL) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    if (url.hostname !== "cloudflare-dns.com") return new Response("offline test", { status: 500 });
    dns.duringLookup?.();
    const data = dns.answers.get(url.searchParams.get("name") ?? "") ?? [];
    return Response.json({ Answer: data.map((d) => ({ type: 16, data: `"${d}"` })) });
  }),
);

const { ssoRoutes } = await import("./sso");

const OWNER = "owner";
const ORG = "org1";
const PROVIDER = "acme";
const TOKEN = "tok-proven-for-attacker-test";

let db: TestD1;
let app: Hono<{ Bindings: Env; Variables: Variables }>;
let env: Env;

beforeEach(() => {
  db = createTestD1();
  env = { DB: db, BETTER_AUTH_URL: "http://localhost:8787" } as unknown as Env;
  app = new Hono<{ Bindings: Env; Variables: Variables }>();
  app.route("/api", ssoRoutes);
  dns.answers.clear();
  dns.duringLookup = null;

  const now = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked)
     VALUES (?, 'Owner', 'owner@attacker.test', 1, ?, ?, 1, 0)`,
    OWNER, now, now,
  );
  db.query(`INSERT INTO "organization" (id, name, slug, createdAt) VALUES (?, 'Team', 'team', ?)`, ORG, now);
  db.query(
    `INSERT INTO "member" (id, organizationId, userId, role, createdAt) VALUES ('m1', ?, ?, 'owner', ?)`,
    ORG, OWNER, now,
  );
  db.query(
    `INSERT INTO "ssoProvider" (id, issuer, oidcConfig, providerId, organizationId, userId, domain, domainVerified)
     VALUES ('sp1', 'https://idp.attacker.test', '{}', ?, ?, ?, 'attacker.test', 0)`,
    PROVIDER, ORG, OWNER,
  );
  db.query(
    `INSERT INTO "verification" (id, identifier, value, expiresAt, createdAt, updatedAt)
     VALUES ('v1', ?, ?, ?, ?, ?)`,
    `_better-auth-token-${PROVIDER}`, TOKEN, new Date(Date.now() + 86_400_000).toISOString(), now, now,
  );
  // The attacker controls attacker.test, so the proof record really is there.
  dns.answers.set(`_better-auth-token-${PROVIDER}.attacker.test`, [TOKEN]);
});

function verify() {
  return app.request(
    `/api/sso/providers/${PROVIDER}/verify`,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${OWNER}`, "Content-Type": "application/json" },
      body: JSON.stringify({ organizationId: ORG }),
    },
    env,
  );
}

const row = () =>
  db.query(`SELECT domain, domainVerified FROM "ssoProvider" WHERE providerId = ?`, PROVIDER)[0] as {
    domain: string;
    domainVerified: number;
  };

describe("SSO domain verification", () => {
  it("marks the provider verified when the TXT record for its domain is published", async () => {
    const res = await verify();
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ providerId: PROVIDER, domainVerified: true });
    expect(row()).toEqual({ domain: "attacker.test", domainVerified: 1 });
  });

  it("refuses when the provider's domain is changed while the lookup is in flight", async () => {
    // GHSA-8c5h-wx78-2cfg's race, against our route: the proof is for
    // attacker.test, but by the time it lands the provider claims victim.test.
    dns.duringLookup = () => {
      db.query(
        `UPDATE "ssoProvider" SET domain = 'victim.test', domainVerified = 0 WHERE providerId = ?`,
        PROVIDER,
      );
    };
    const res = await verify();
    expect(res.status).toBe(409);
    expect(await res.json()).toMatchObject({ code: "SSO_PROVIDER_CHANGED" });
    expect(row()).toEqual({ domain: "victim.test", domainVerified: 0 });
  });

  it("still succeeds when a parallel verify of the same domain got there first", async () => {
    dns.duringLookup = () => {
      db.query(`UPDATE "ssoProvider" SET domainVerified = 1 WHERE providerId = ?`, PROVIDER);
    };
    const res = await verify();
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ domainVerified: true });
    expect(row()).toEqual({ domain: "attacker.test", domainVerified: 1 });
  });

  it("does not verify when the TXT record is missing", async () => {
    dns.answers.clear();
    const res = await verify();
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ domainVerified: false });
    expect(row().domainVerified).toBe(0);
  });
});
