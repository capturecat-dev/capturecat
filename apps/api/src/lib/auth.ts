/**
 * Better Auth instance for the CaptureCat Worker.
 *
 * Replaces the old Firebase JWT verification entirely. Identity now lives in
 * D1 (`user` / `session` / `account` / `verification`), billing state lives in
 * the `subscription` table written by @better-auth/stripe, and native clients
 * authenticate with `Authorization: Bearer <session.token>` via the bearer
 * plugin.
 *
 * App Attest is ORTHOGONAL to this file — `lib/app-attest.ts` verifies Apple
 * attestation/assertion objects with raw WebCrypto and never touches the auth
 * provider. Nothing here changes its behaviour.
 *
 * LIFECYCLE NOTE (Workers): `env` bindings only exist inside a request, and the
 * same `env` object is reused for every request in an isolate. So the auth
 * instance is built ONCE per isolate and memoised on env identity — rebuilding
 * per request would spin up a fresh Kysely instance and re-sign the Apple
 * client secret on every call.
 */

import { betterAuth } from "better-auth";
import { admin, bearer, oneTimeToken, organization } from "better-auth/plugins";
import { createAuthMiddleware } from "better-auth/api";
import { sso } from "@better-auth/sso";
import { APIError } from "better-auth/api";
import { importPKCS8, SignJWT } from "jose";
// All Stripe configuration (client, plans, webhook secret, lifecycle hooks)
// lives in ./stripe — do not inline it here.
import { buildStripePlugin } from "./stripe";
import type { Env } from "../types";
import { webOrigins } from "./origins";

/**
 * Sign in with Apple does not use a static client secret — it wants an ES256
 * JWT signed with the .p8 key from the Apple developer portal, valid for at
 * most 6 months. Signing is cheap (WebCrypto) but the factory below is only
 * awaited once per isolate anyway, so a module-scope cache with a 90-day TTL
 * is plenty.
 */
let appleSecretCache: { clientId: string; token: string; expiresAt: number } | null = null;

const APPLE_SECRET_TTL_SEC = 90 * 24 * 60 * 60; // 90d — Apple's hard cap is 6 months.

async function appleClientSecret(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (
    appleSecretCache &&
    appleSecretCache.clientId === env.APPLE_CLIENT_ID &&
    now < appleSecretCache.expiresAt - 60
  ) {
    return appleSecretCache.token;
  }

  // `wrangler secret put` preserves real newlines, but .dev.vars stores the key
  // as a single line with escaped \n — normalise both forms before importing.
  const pem = env.APPLE_PRIVATE_KEY.replace(/\\n/g, "\n").trim();
  const key = await importPKCS8(pem, "ES256");

  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env.APPLE_KEY_ID })
    .setIssuer(env.APPLE_TEAM_ID)
    .setSubject(env.APPLE_CLIENT_ID) // the SERVICES ID, not the app bundle id
    .setAudience("https://appleid.apple.com")
    .setIssuedAt(now)
    .setExpirationTime(now + APPLE_SECRET_TTL_SEC)
    .sign(key);

  appleSecretCache = {
    clientId: env.APPLE_CLIENT_ID,
    token,
    expiresAt: now + APPLE_SECRET_TTL_SEC,
  };
  return token;
}

/** The macOS app's bundle identifier — used only when verifying a natively
 *  obtained Apple id_token. We use the browser leg, so this is belt-and-braces. */
const APPLE_APP_BUNDLE_IDENTIFIER = "so.capturecat.CaptureCat";

export function hasGoogleConfig(env: Env): boolean {
  return Boolean(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET);
}

export function hasAppleConfig(env: Env): boolean {
  return Boolean(
    env.APPLE_CLIENT_ID && env.APPLE_TEAM_ID && env.APPLE_KEY_ID && env.APPLE_PRIVATE_KEY,
  );
}

export function buildAuth(env: Env) {
  if (!env.BETTER_AUTH_SECRET) {
    // Better Auth falls back to a dev default; on a Worker that would silently
    // make every session token forgeable, so shout loudly.
    console.error("BETTER_AUTH_SECRET is not set — sessions are NOT secure");
  }
  if (!hasGoogleConfig(env) && !hasAppleConfig(env)) {
    console.error("No social provider configured — sign-in will be impossible");
  }

  // True only for the deployed Worker. Two cookie decisions hang off this, and
  // both BREAK local dev if applied there: a `.capturecat.so` Domain makes the
  // browser drop the session cookie on localhost, and a `Secure` state cookie
  // is refused over http://localhost by Safari.
  const isProdOrigin = env.BETTER_AUTH_URL.startsWith("https://");

  return betterAuth({
    // Better Auth duck-types the D1 binding ("batch" + "exec" + "prepare") and
    // swaps in its own D1SqliteDialect. Nothing else to configure.
    database: env.DB,
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.BETTER_AUTH_URL,
    basePath: "/api/auth",
    appName: "CaptureCat",
    telemetry: { enabled: false },

    // Social-only. There is no password surface to attack.
    emailAndPassword: { enabled: false },

    session: {
      expiresIn: 60 * 60 * 24 * 30, // 30 days
      updateAge: 60 * 60 * 24, // slide the expiry once a day
      // cookieCache stays OFF: the desktop client is cookie-less, so it would
      // buy nothing and would let a revoked session live on in a cookie.
    },

    user: {
      additionalFields: {
        // `input: false` is load-bearing: it makes these UNSETTABLE by any
        // client payload. Without it a sign-up body could self-grant tester
        // and self-clear blocked.
        tester: { type: "boolean", required: false, defaultValue: false, input: false },
        blocked: { type: "boolean", required: false, defaultValue: false, input: false },
      },
    },

    socialProviders: {
      // Registered conditionally so a half-configured environment (e.g. Google
      // set up but the Apple .p8 not yet minted) still boots — the async Apple
      // factory throwing would otherwise fail auth-context creation and 500
      // EVERY auth request, Google included.
      ...(hasGoogleConfig(env)
        ? {
            google: {
              clientId: env.GOOGLE_CLIENT_ID,
              clientSecret: env.GOOGLE_CLIENT_SECRET,
            },
          }
        : {}),
      ...(hasAppleConfig(env)
        ? {
            apple: async () => ({
              clientId: env.APPLE_CLIENT_ID,
              clientSecret: await appleClientSecret(env),
              appBundleIdentifier: APPLE_APP_BUNDLE_IDENTIFIER,
            }),
          }
        : {}),
    },

    hooks: {
      // Feature-gate SSO provider management: registering/updating a provider
      // is the paid enterprise surface. Runs before the plugin handler; the
      // sign-in and callback endpoints are untouched.
      before: createAuthMiddleware(async (ctx) => {
        const gated = ["/sso/register", "/sso/update-provider"];
        if (!gated.includes(ctx.path)) return;
        const userId = ctx.context.session?.user?.id;
        if (!userId) {
          // No resolved session on the hook context — the plugin's own auth
          // requirement will produce the 401.
          return;
        }
        const { featuresForTier } = await import("./plans");
        const { resolveTier } = await import("./entitlement");
        const tier = await resolveTier(env.DB, userId, undefined);
        if (tier === "blocked") {
          throw new APIError("FORBIDDEN", { message: "Account blocked" });
        }
        const features = await featuresForTier(env.DB, tier);
        if (!(features as { sso?: boolean }).sso) {
          throw new APIError("FORBIDDEN", {
            message: "SSO requires the Business plan. Upgrade to configure an identity provider.",
          });
        }
      }),
    },

    trustedOrigins: [
      // REQUIRED for Apple: the provider uses response_mode=form_post, so the
      // callback arrives as a cross-site POST from this origin and Better Auth
      // runs an origin check on it.
      "https://appleid.apple.com",
      // Every web origin (marketing site, app + admin subdomains, local dev
      // servers, BETTER_AUTH_TRUSTED_ORIGINS extras) comes from the ONE list
      // the CORS/CSRF middleware uses, so the two layers cannot disagree —
      // a hand-copied subset here once silently omitted app.capturecat.so.
      // localhost appears only when this Worker is itself running locally,
      // so a production deploy can never trust it.
      ...webOrigins(env),
      // RFC 8252 §7.3 loopback redirects for the desktop app. The port is
      // random per sign-in attempt and CANNOT be pre-registered, hence the
      // wildcard. Literal IPs only — `localhost` is deliberately absent
      // (RFC 8252 §8.3: it is DNS-rebindable).
      "http://127.0.0.1:*",
      "http://[::1]:*",
    ],

    advanced: {
      // Share the session cookie across *.capturecat.so.
      //
      // Without this the cookie is host-only on api.capturecat.so, so a Next.js
      // server component on capturecat.so never receives it and cannot do a
      // server-side session read at all — every guard degrades to a
      // client-side flash. The domain MUST be explicit: Better Auth otherwise
      // defaults it to `new URL(baseURL).hostname`, i.e. api.capturecat.so,
      // which does not help.
      //
      // Gated on the production origin. In dev (http://localhost:8787) a
      // `.capturecat.so` Domain makes the browser silently DROP the cookie and
      // sign-in appears to succeed while no session ever sticks.
      //
      // Cost, stated plainly: every *.capturecat.so host can now read this
      // cookie. Never serve untrusted content from a subdomain.
      ...(isProdOrigin
        ? {
            crossSubDomainCookies: {
              enabled: true,
              domain: ".capturecat.so",
            },
          }
        : {}),
      cookies: {
        // REQUIRED for Apple in PRODUCTION. The OAuth state cookie defaults to
        // SameSite=Lax, which browsers will NOT send on Apple's cross-site
        // form_post callback — parseGenericState then throws
        // `state_security_mismatch` and Apple sign-in fails 100% of the time.
        //
        // Deliberately NOT using account.skipStateCookieCheck: that disables
        // the CSRF binding globally.
        //
        // Gated on the production origin, because `SameSite=None` REQUIRES
        // `Secure`, and a Secure cookie is refused over http://localhost by
        // Safari. Applying it in dev breaks GOOGLE sign-in too — the state
        // cookie is never stored, the callback finds nothing, and every attempt
        // ends at `?error=state_mismatch` with no user ever created. Locally the
        // default Lax is correct: the callback is same-origin, and Apple cannot
        // be tested against localhost anyway (it rejects http:// return URLs).
        ...(isProdOrigin
          ? { state: { attributes: { sameSite: "none" as const, secure: true } } }
          : {}),
      },
    },

    plugins: [
      // Lets `Authorization: Bearer <session.token>` resolve to a session, both
      // through auth.handler() and through auth.api.* calls that pass headers.
      // Left at defaults (requireSignature falsy) so the RAW session token the
      // desktop app stores in the Keychain works as-is.
      bearer(),

      // Role-based admin authority. Admin-ness lives on the user row (`role`),
      // so it can be granted from the admin UI instead of being an env var that
      // needs a redeploy.
      //
      // SECURITY: five of this plugin's fifteen endpoints are denied at the
      // router in src/index.ts — see the deny-list there for why each one is a
      // privilege-escalation or blast-radius problem. `adminRoles` is stated
      // explicitly rather than left to default so widening it is a visible diff.
      admin({
        defaultRole: "user",
        adminRoles: ["admin"],
      }),

      // Backs the desktop loopback code exchange. `disableClientRequest` means
      // the generate endpoint is unreachable over HTTP — only server-side
      // auth.api.generateOneTimeToken() can mint one.
      oneTimeToken({
        storeToken: "hashed",
        expiresIn: 2, // minutes
        disableClientRequest: true,
        disableSetSessionCookie: true,
      }),

      // Teams. Orgs/members/invitations (schema in 0022). Any signed-in
      // user may create ONE org; SSO and future seat pricing are the paid
      // gates, not org creation itself — a free team library is the hook.
      // Invitations are link-based: no email sender is wired, so the
      // dashboard surfaces a copyable accept URL instead. The callback is
      // still required or the plugin refuses to create invitations.
      organization({
        organizationLimit: 1,
        invitationExpiresIn: 60 * 60 * 24 * 7,
        async sendInvitationEmail() {
          // Deliberate no-op — invite links are copied from the dashboard.
        },
      }),

      // Enterprise SSO (OIDC + SAML). Provider registration is entitlement-
      // gated in the `before` hook below; sign-in/callback endpoints stay
      // open (they must be, for the customer's users to authenticate).
      sso({
        domainVerification: { enabled: true },
      }),

      // Billing. Registers /subscription/{upgrade,cancel,restore,list,
      // success,billing-portal} and /stripe/webhook under basePath. Configured
      // in ./stripe so plans and webhook handling stay in one place.
      buildStripePlugin(env),
    ],
  });
}

export type Auth = ReturnType<typeof buildAuth>;

/**
 * One instance per isolate, keyed on `env` identity. Workers reuses the same
 * `env` object for the lifetime of an isolate, so this is effectively a
 * module-level singleton that still survives the (rare) case of a differing env.
 */
let cached: { env: Env; auth: Auth } | null = null;

export function getAuth(env: Env): Auth {
  if (cached && cached.env === env) return cached.auth;
  const auth = buildAuth(env);
  cached = { env, auth };
  return auth;
}
