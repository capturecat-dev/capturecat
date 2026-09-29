/**
 * /api/sso — the CaptureCat side of enterprise SSO, on top of Better Auth's
 * `@better-auth/sso` plugin (which owns /api/auth/sso/* : register, sign-in,
 * callbacks, update, delete).
 *
 * What the plugin does NOT give an org admin, and this file does:
 *
 *   GET  /sso/overview?organizationId=…
 *        Everything the Team page needs in one call: whether the caller's
 *        plan includes SSO, the org's providers with verification state,
 *        the DNS TXT record still to publish, and the URLs to paste into
 *        the identity provider (redirect URI, SAML ACS + SP metadata).
 *
 *   POST /sso/providers/:providerId/verify
 *        Checks the ownership TXT record over DNS-over-HTTPS and flips
 *        `domainVerified`. The plugin's own /sso/verify-domain needs
 *        node:dns, which is not something to bet a customer onboarding on
 *        inside a Worker; the record format is the plugin's, so either path
 *        accepts the same TXT value.
 *
 * Why verification matters: with `domainVerification.enabled` every SSO
 * sign-in is refused until the provider's domain is verified. A provider an
 * admin cannot verify is a provider nobody can use.
 */

import { Hono } from "hono";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement } from "../lib/entitlement";
import { featuresForTier } from "../lib/plans";
import { parseJsonBody } from "../lib/validate";

export const ssoRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

/** Mirrors the plugin: `_better-auth-token-<providerId>` (default prefix). */
const VERIFICATION_PREFIX = "better-auth-token";
const verificationIdentifier = (providerId: string) => `_${VERIFICATION_PREFIX}-${providerId}`;
const TOKEN_TTL_MS = 7 * 24 * 3600 * 1000;

interface ProviderRow {
  id: string;
  providerId: string;
  issuer: string;
  domain: string;
  organizationId: string | null;
  userId: string | null;
  oidcConfig: string | null;
  samlConfig: string | null;
  domainVerified: number | null;
}

async function orgRole(db: D1Database, orgId: string, uid: string): Promise<string | null> {
  const row = await db
    .prepare('SELECT role FROM "member" WHERE "organizationId" = ? AND "userId" = ? LIMIT 1')
    .bind(orgId, uid)
    .first<{ role: string }>();
  return row?.role ?? null;
}

const canManage = (role: string | null) => role === "owner" || role === "admin";

async function activeVerification(db: D1Database, providerId: string) {
  const row = await db
    .prepare(
      `SELECT "value", "expiresAt" FROM "verification"
        WHERE "identifier" = ? ORDER BY "createdAt" DESC LIMIT 1`,
    )
    .bind(verificationIdentifier(providerId))
    .first<{ value: string; expiresAt: string | number }>();
  if (!row) return null;
  const exp = typeof row.expiresAt === "number" ? row.expiresAt : Date.parse(row.expiresAt);
  return Number.isFinite(exp) && exp > Date.now() ? { value: row.value, expiresAt: new Date(exp).toISOString() } : null;
}

/** Mint a fresh ownership token in the plugin's own table + format so the
 *  plugin's verify endpoint would accept it just the same. */
async function mintVerification(db: D1Database, providerId: string) {
  const bytes = new Uint8Array(18);
  crypto.getRandomValues(bytes);
  const value = Array.from(bytes, (b) => "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"[b % 62]).join("");
  const now = new Date().toISOString();
  const expiresAt = new Date(Date.now() + TOKEN_TTL_MS).toISOString();
  await db
    .prepare(
      `INSERT INTO "verification" ("id", "identifier", "value", "expiresAt", "createdAt", "updatedAt")
       VALUES (?, ?, ?, ?, ?, ?)`,
    )
    .bind(crypto.randomUUID(), verificationIdentifier(providerId), value, expiresAt, now, now)
    .run();
  return { value, expiresAt };
}

function providerView(env: Env, p: ProviderRow, verification: { value: string; expiresAt: string } | null) {
  const authBase = `${new URL(env.BETTER_AUTH_URL).origin}/api/auth`;
  const type = p.samlConfig ? "saml" : "oidc";
  let oidc: { discoveryEndpoint?: string; clientIdLastFour?: string } | null = null;
  if (p.oidcConfig) {
    try {
      const cfg = JSON.parse(p.oidcConfig) as { discoveryEndpoint?: string; clientId?: string };
      oidc = {
        discoveryEndpoint: cfg.discoveryEndpoint,
        clientIdLastFour: cfg.clientId ? `…${cfg.clientId.slice(-4)}` : undefined,
      };
    } catch {
      oidc = null;
    }
  }
  return {
    providerId: p.providerId,
    type,
    issuer: p.issuer,
    domain: p.domain,
    domainVerified: p.domainVerified === 1,
    oidc,
    // What the admin pastes into Okta / Entra / Google Workspace.
    redirectUri: `${authBase}/sso/callback/${encodeURIComponent(p.providerId)}`,
    samlAcsUrl: `${authBase}/sso/saml2/sp/acs/${encodeURIComponent(p.providerId)}`,
    samlMetadataUrl: `${authBase}/sso/saml2/sp/metadata?providerId=${encodeURIComponent(p.providerId)}`,
    // What the admin publishes in DNS to prove the domain is theirs.
    dnsRecord:
      p.domainVerified === 1 || !verification
        ? null
        : {
            type: "TXT",
            name: `${verificationIdentifier(p.providerId)}.${p.domain}`,
            value: verification.value,
            expiresAt: verification.expiresAt,
          },
  };
}

ssoRoutes.get("/sso/overview", requireAuth, requireEntitlement(), async (c) => {
  const orgId = c.req.query("organizationId") ?? "";
  if (!orgId) return c.json({ error: "organizationId is required" }, 400);
  const uid = c.get("user").uid;
  const role = await orgRole(c.env.DB, orgId, uid);
  if (!role) return c.json({ error: "Not a member of this team" }, 403);

  const features = await featuresForTier(c.env.DB, c.get("entitlement").tier, c.get("entitlement").planName);
  const rows = await c.env.DB
    .prepare('SELECT * FROM "ssoProvider" WHERE "organizationId" = ? ORDER BY "domain"')
    .bind(orgId)
    .all<ProviderRow>();

  const providers = [];
  for (const p of rows.results ?? []) {
    let verification = p.domainVerified === 1 ? null : await activeVerification(c.env.DB, p.providerId);
    // The plugin's token lives 7 days; an admin who comes back later needs
    // a record to publish, not a dead end.
    if (!verification && p.domainVerified !== 1 && canManage(role)) {
      verification = await mintVerification(c.env.DB, p.providerId);
    }
    providers.push(providerView(c.env, p, verification));
  }

  return c.json({
    enabled: features.sso,
    canManage: canManage(role),
    role,
    providers,
    // The plugin refuses sign-in for a provider whose domain is unverified,
    // so the UI leads with that step.
    signInUrl: `${new URL(c.env.BETTER_AUTH_URL).origin}/api/auth/sign-in/sso`,
  });
});

const VerifySchema = z.object({ organizationId: z.string().min(1) });

/** TXT lookup over Cloudflare DoH — resolves in Workers without node:dns. */
async function lookupTxt(name: string): Promise<string[]> {
  try {
    const resp = await fetch(
      `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(name)}&type=TXT`,
      { headers: { Accept: "application/dns-json" } },
    );
    const dns = (await resp.json().catch(() => ({}))) as { Answer?: Array<{ type: number; data: string }> };
    return (dns.Answer ?? [])
      .filter((a) => a.type === 16)
      // DoH returns TXT data quoted, possibly as several quoted chunks.
      .map((a) => a.data.replace(/^"|"$/g, "").replace(/"\s*"/g, "").trim());
  } catch {
    return [];
  }
}

ssoRoutes.post("/sso/providers/:providerId/verify", requireAuth, requireEntitlement(), async (c) => {
  const parsed = await parseJsonBody(c.req, VerifySchema, { emptyOnInvalidJson: true });
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const providerId = c.req.param("providerId");
  const uid = c.get("user").uid;

  const provider = await c.env.DB
    .prepare('SELECT * FROM "ssoProvider" WHERE "providerId" = ? AND "organizationId" = ?')
    .bind(providerId, parsed.data.organizationId)
    .first<ProviderRow>();
  if (!provider) return c.json({ error: "Provider not found" }, 404);
  if (!canManage(await orgRole(c.env.DB, parsed.data.organizationId, uid))) {
    return c.json({ error: "Only team owners and admins can verify a domain" }, 403);
  }
  if (provider.domainVerified === 1) {
    return c.json({ providerId, domainVerified: true, found: [] });
  }

  let verification = await activeVerification(c.env.DB, providerId);
  if (!verification) verification = await mintVerification(c.env.DB, providerId);

  const identifier = verificationIdentifier(providerId);
  const name = `${identifier}.${provider.domain}`;
  const records = await lookupTxt(name);
  const expected = [verification.value, `${identifier}=${verification.value}`];
  const ok = records.some((r) => expected.includes(r));

  if (ok) {
    await c.env.DB
      .prepare('UPDATE "ssoProvider" SET "domainVerified" = 1 WHERE "providerId" = ?')
      .bind(providerId)
      .run();
  }
  return c.json({
    providerId,
    domainVerified: ok,
    found: records,
    dnsRecord: ok ? null : { type: "TXT", name, value: verification.value, expiresAt: verification.expiresAt },
  });
});
