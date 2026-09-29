import { z } from "zod";
import { TRPCError } from "@trpc/server";

import { apiFetch } from "@/lib/session";
import { authedProcedure, createTRPCRouter } from "@/lib/trpc/init";

/**
 * Enterprise SSO for the Team page. Provider CRUD goes to Better Auth's SSO
 * plugin on the API (/api/auth/sso/*); the overview and domain verification
 * are CaptureCat routes (/api/sso/*). Everything is server-side so the
 * cookie is forwarded and the API's CSRF check sees a trusted Origin.
 */

export type SsoProvider = {
  providerId: string;
  type: "oidc" | "saml";
  issuer: string;
  domain: string;
  domainVerified: boolean;
  oidc: { discoveryEndpoint?: string; clientIdLastFour?: string } | null;
  redirectUri: string;
  samlAcsUrl: string;
  samlMetadataUrl: string;
  dnsRecord: { type: "TXT"; name: string; value: string; expiresAt: string } | null;
};

export type SsoOverview = {
  enabled: boolean;
  canManage: boolean;
  role: string;
  providers: SsoProvider[];
  signInUrl: string;
};

async function fail(res: Response, fallback: string): Promise<never> {
  const body = (await res.json().catch(() => ({}))) as { error?: string | { message?: string }; message?: string };
  const message =
    typeof body.error === "string"
      ? body.error
      : body.error?.message ?? body.message ?? fallback;
  throw new TRPCError({
    code: res.status === 403 ? "FORBIDDEN" : res.status === 404 ? "NOT_FOUND" : "BAD_REQUEST",
    message,
  });
}

const providerIdSchema = z
  .string()
  .trim()
  .toLowerCase()
  .regex(/^[a-z0-9][a-z0-9-]{1,62}$/, "Use letters, digits and dashes, e.g. acme-okta");

export const ssoRouter = createTRPCRouter({
  overview: authedProcedure
    .input(z.object({ organizationId: z.string().min(1) }))
    .query(async ({ input }) => {
      const res = await apiFetch(
        `/api/sso/overview?organizationId=${encodeURIComponent(input.organizationId)}`,
      );
      if (!res.ok) await fail(res, "Could not load single sign-on settings");
      return (await res.json()) as SsoOverview;
    }),

  registerOidc: authedProcedure
    .input(
      z.object({
        organizationId: z.string().min(1),
        providerId: providerIdSchema,
        domain: z
          .string()
          .trim()
          .toLowerCase()
          .regex(/^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$/, "Enter your email domain, e.g. acme.com"),
        issuer: z.string().trim().url("Issuer must be a URL, e.g. https://acme.okta.com"),
        clientId: z.string().trim().min(1, "Client ID is required"),
        clientSecret: z.string().trim().min(1, "Client secret is required"),
        pkce: z.boolean().default(true),
      }),
    )
    .mutation(async ({ input }) => {
      const issuer = input.issuer.replace(/\/$/, "");
      const res = await apiFetch("/api/auth/sso/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          providerId: input.providerId,
          issuer,
          domain: input.domain,
          organizationId: input.organizationId,
          oidcConfig: {
            clientId: input.clientId,
            clientSecret: input.clientSecret,
            discoveryEndpoint: `${issuer}/.well-known/openid-configuration`,
            scopes: ["openid", "email", "profile"],
            pkce: input.pkce,
          },
        }),
      });
      if (!res.ok) await fail(res, "Could not register the identity provider");
      const body = (await res.json()) as {
        providerId: string;
        redirectURI?: string;
        domainVerificationToken?: string;
      };
      return {
        providerId: body.providerId,
        redirectUri: body.redirectURI ?? null,
        domainVerificationToken: body.domainVerificationToken ?? null,
      };
    }),

  registerSaml: authedProcedure
    .input(
      z.object({
        organizationId: z.string().min(1),
        providerId: providerIdSchema,
        domain: z
          .string()
          .trim()
          .toLowerCase()
          .regex(/^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$/, "Enter your email domain, e.g. acme.com"),
        issuer: z.string().trim().url("Issuer (entity ID) must be a URL"),
        entryPoint: z.string().trim().url("Sign-on URL must be a URL"),
        cert: z.string().trim().min(40, "Paste the IdP signing certificate (PEM)"),
        apiOrigin: z.string().url(),
      }),
    )
    .mutation(async ({ input }) => {
      const spEntityId = `${input.apiOrigin}/api/auth/sso/saml2/sp/metadata?providerId=${encodeURIComponent(input.providerId)}`;
      const res = await apiFetch("/api/auth/sso/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          providerId: input.providerId,
          issuer: input.issuer,
          domain: input.domain,
          organizationId: input.organizationId,
          samlConfig: {
            entryPoint: input.entryPoint,
            cert: input.cert,
            callbackUrl: `${input.apiOrigin}/api/auth/sso/saml2/sp/acs/${encodeURIComponent(input.providerId)}`,
            audience: spEntityId,
            wantAssertionsSigned: true,
            spMetadata: {
              metadata: "",
              entityID: spEntityId,
            },
          },
        }),
      });
      if (!res.ok) await fail(res, "Could not register the identity provider");
      const body = (await res.json()) as { providerId: string; domainVerificationToken?: string };
      return { providerId: body.providerId, domainVerificationToken: body.domainVerificationToken ?? null };
    }),

  verifyDomain: authedProcedure
    .input(z.object({ organizationId: z.string().min(1), providerId: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(`/api/sso/providers/${encodeURIComponent(input.providerId)}/verify`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ organizationId: input.organizationId }),
      });
      if (!res.ok) await fail(res, "Could not verify the domain");
      return (await res.json()) as {
        providerId: string;
        domainVerified: boolean;
        found: string[];
        dnsRecord: { type: "TXT"; name: string; value: string; expiresAt: string } | null;
      };
    }),

  remove: authedProcedure
    .input(z.object({ providerId: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch("/api/auth/sso/delete-provider", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ providerId: input.providerId }),
      });
      if (!res.ok) await fail(res, "Could not remove the identity provider");
      return { ok: true };
    }),
});
