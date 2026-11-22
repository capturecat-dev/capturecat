/**
 * Better Auth 1.7 upgrade: SAML providers registered under 1.6 keep working.
 *
 * The REAL Better Auth instance (buildAuth) and the REAL @better-auth/sso
 * plugin against the real migrations (node:sqlite). A SAML provider row is
 * written exactly as the 1.6 plugin stored one from the Team page — IdP
 * entity ID in the top-level `issuer`, no `idpMetadata` — and an SP-initiated
 * sign-in is started for it:
 *
 *   before 0044: 1.7 refuses to build the IdP ("requires idpMetadata.entityID"),
 *                i.e. every pre-upgrade SAML provider would stop signing in;
 *   after 0044:  sign-in redirects to the IdP's sign-on URL with a SAMLRequest.
 *
 * `fetch` is stubbed so nothing can leave the machine.
 */

import { describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { buildAuth } from "./auth";

vi.stubGlobal("fetch", vi.fn(async () => new Response("offline test", { status: 500 })));

const MIGRATION = "0044_sso_saml_idp_entity.sql";
const API = "http://localhost:8787";
const IDP_ENTITY = "https://idp.acme.test/entity";
const IDP_SSO = "https://idp.acme.test/sso/saml";
const SP_ENTITY = `${API}/api/auth/sso/saml2/sp/metadata?providerId=acme-saml`;

// What the 1.6 plugin stored for a Team-page SAML registration.
const SAML_FROM_16 = {
  issuer: IDP_ENTITY,
  entryPoint: IDP_SSO,
  cert: "MIIBszCCAVmgAwIBAgIUTESTCERTIFICATEONLYNOTREAL0wCgYIKoZIzj0EAwIw",
  callbackUrl: `${API}/api/auth/sso/saml2/sp/acs/acme-saml`,
  audience: SP_ENTITY,
  wantAssertionsSigned: true,
  spMetadata: { metadata: "", entityID: SP_ENTITY },
};

function seed(db: TestD1) {
  const now = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked)
     VALUES ('owner', 'Owner', 'owner@acme.test', 1, ?, ?, 0, 0)`,
    now, now,
  );
  db.query(`INSERT INTO "organization" (id, name, slug, createdAt) VALUES ('org1', 'Acme', 'acme', ?)`, now);
  const insert = (id: string, providerId: string, domain: string, saml: unknown, oidc: unknown) =>
    db.query(
      `INSERT INTO "ssoProvider" (id, issuer, samlConfig, oidcConfig, providerId, organizationId, userId, domain, domainVerified)
       VALUES (?, ?, ?, ?, ?, 'org1', 'owner', ?, 1)`,
      id, IDP_ENTITY, saml === null ? null : JSON.stringify(saml), oidc === null ? null : JSON.stringify(oidc), providerId, domain,
    );
  insert("sp-saml", "acme-saml", "acme.test", SAML_FROM_16, null);
  insert("sp-xml", "acme-xml", "xml.acme.test", { ...SAML_FROM_16, idpMetadata: { metadata: "<EntityDescriptor/>" } }, null);
  insert("sp-oidc", "acme-oidc", "oidc.acme.test", null, { clientId: "c", clientSecret: "s" });
}

function envFor(db: TestD1): Env {
  return {
    DB: db,
    BETTER_AUTH_URL: API,
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
    GOOGLE_CLIENT_ID: "google-test",
    GOOGLE_CLIENT_SECRET: "google-test-secret",
    STRIPE_SECRET_KEY: "sk_test_offline",
    STRIPE_WEBHOOK_SECRET: "whsec_offline",
    STRIPE_PRO_PRICE_ID: "price_pro_monthly",
  } as unknown as Env;
}

function startSamlSignIn(db: TestD1) {
  return buildAuth(envFor(db)).api.signInSSO({
    body: { email: "jo@acme.test", callbackURL: "http://localhost:3200/app" },
  });
}

const samlConfig = (db: TestD1, providerId: string) =>
  db.query(`SELECT samlConfig FROM "ssoProvider" WHERE providerId = ?`, providerId)[0]?.samlConfig as string | null;

describe("migration 0044 — SAML providers from 1.6 on Better Auth 1.7", () => {
  it("1.7 cannot start sign-in for a 1.6 SAML row until the migration runs", async () => {
    const db = createTestD1({ before: MIGRATION });
    seed(db);
    await expect(startSamlSignIn(db)).rejects.toThrow(/idpMetadata\.entityID/);

    db.migrate(MIGRATION);
    const res = (await startSamlSignIn(db)) as { url?: string };
    expect(res.url).toBeTruthy();
    const url = new URL(res.url!);
    expect(`${url.origin}${url.pathname}`).toBe(IDP_SSO);
    expect(url.searchParams.get("SAMLRequest")).toBeTruthy();
  });

  it("sets idpMetadata.entityID from issuer, keeps everything else, and is idempotent", () => {
    const db = createTestD1({ before: MIGRATION });
    seed(db);
    const xmlBefore = samlConfig(db, "acme-xml");
    const oidcBefore = db.query(`SELECT oidcConfig, samlConfig FROM "ssoProvider" WHERE providerId = 'acme-oidc'`)[0];

    db.migrate(MIGRATION);
    const migrated = JSON.parse(samlConfig(db, "acme-saml")!);
    expect(migrated).toEqual({ ...SAML_FROM_16, idpMetadata: { entityID: IDP_ENTITY } });
    // Untouched: a row that already has IdP metadata XML, and OIDC rows.
    expect(samlConfig(db, "acme-xml")).toBe(xmlBefore);
    expect(db.query(`SELECT oidcConfig, samlConfig FROM "ssoProvider" WHERE providerId = 'acme-oidc'`)[0]).toEqual(oidcBefore);

    const once = samlConfig(db, "acme-saml");
    db.migrate(MIGRATION);
    expect(samlConfig(db, "acme-saml")).toBe(once);
  });
});

describe("Team page SAML registration on Better Auth 1.7", () => {
  // The body apps/web/src/lib/trpc/routers/sso.ts `registerSaml` sends (it
  // lives in another package, so the shape is restated here). 1.7 requires
  // `idpMetadata` — the 1.6 body without it is refused, which is what the
  // second case pins.
  const body = (withIdpMetadata: boolean) => ({
    providerId: "acme-saml",
    issuer: IDP_ENTITY,
    domain: "acme.test",
    organizationId: "org1",
    samlConfig: {
      entryPoint: IDP_SSO,
      cert: SAML_FROM_16.cert,
      ...(withIdpMetadata ? { idpMetadata: { entityID: IDP_ENTITY } } : {}),
      audience: SP_ENTITY,
      wantAssertionsSigned: true,
      spMetadata: { entityID: SP_ENTITY },
    },
  });

  function setup() {
    const db = createTestD1();
    const now = new Date().toISOString();
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked)
       VALUES ('owner', 'Owner', 'owner@acme.test', 1, ?, ?, 1, 0)`,
      now, now,
    );
    db.query(
      `INSERT INTO "session" (id, expiresAt, token, createdAt, updatedAt, userId)
       VALUES ('s1', ?, 'owner-token', ?, ?, 'owner')`,
      new Date(Date.now() + 86_400_000).toISOString(), now, now,
    );
    db.query(`INSERT INTO "organization" (id, name, slug, createdAt) VALUES ('org1', 'Acme', 'acme', ?)`, now);
    db.query(`INSERT INTO "member" (id, organizationId, userId, role, createdAt) VALUES ('m1', 'org1', 'owner', 'owner', ?)`, now);
    // Testers get Pro; SSO is a Business feature, so grant it to Pro here.
    db.query(`UPDATE "plan" SET features = json_set(features, '$.sso', json('true')) WHERE name = 'pro'`);
    return db;
  }

  const register = (db: TestD1, b: unknown) =>
    buildAuth(envFor(db)).handler(
      new Request(`${API}/api/auth/sso/register`, {
        method: "POST",
        headers: { Authorization: "Bearer owner-token", "Content-Type": "application/json", Origin: "http://localhost:3200" },
        body: JSON.stringify(b),
      }),
    );

  it("accepts the new body, stores the IdP entity ID, and can start sign-in", async () => {
    const db = setup();
    const res = await register(db, body(true));
    expect(res.status, await res.clone().text()).toBe(200);
    expect(JSON.parse(samlConfig(db, "acme-saml")!).idpMetadata).toEqual({ entityID: IDP_ENTITY });

    db.query(`UPDATE "ssoProvider" SET domainVerified = 1 WHERE providerId = 'acme-saml'`);
    const start = (await startSamlSignIn(db)) as { url?: string };
    expect(start.url?.startsWith(`${IDP_SSO}?`)).toBe(true);
  });

  it("refuses the 1.6 body that had no idpMetadata", async () => {
    const db = setup();
    const res = await register(db, body(false));
    expect(res.status).toBe(400);
    expect(samlConfig(db, "acme-saml")).toBeUndefined();
  });
});
