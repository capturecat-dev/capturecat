import { createMiddleware } from "hono/factory";
import type { Env, Variables } from "../types";
import { getAuth } from "../lib/auth";
import { webOrigins } from "../lib/origins";

/**
 * Bearer-token authentication against a Better Auth session.
 *
 * The output shape (`c.set("user", { uid, email, claims })`) is deliberately
 * unchanged from the Firebase era: every route reads `c.get("user").uid`, so
 * routes/upload.ts, routes/video.ts, routes/delete.ts, routes/ai.ts and
 * routes/attest.ts needed no edits. `uid` now holds a Better Auth `user.id`.
 *
 * WHAT CHANGED, SECURITY-WISE: the old middleware read `paid` / `tester` /
 * `blocked` out of the Firebase ID token, which meant a stale token could
 * carry a `paid` claim after a subscription lapsed. There is no token claim
 * any more — `tester` and `blocked` are columns on the server-owned `user` row
 * (declared `input: false`, so unsettable by any client payload) and paid
 * status is read from the `subscription` table on every request.
 *
 * COST NOTE: this is one D1 read per authenticated request (the session
 * lookup), where Firebase JWT verification was stateless. That is the price of
 * instant revocation — a signed-out or deleted session stops working on the
 * very next call. If it ever hurts, cache on a hash of the bearer token; do
 * NOT loosen the session check.
 */
export const requireAuth = createMiddleware<{
  Bindings: Env;
  Variables: Variables;
}>(async (c, next) => {
  const authHeader = c.req.header("Authorization");
  const usingCookie = !authHeader?.startsWith("Bearer ");

  // Cookie auth exists for the WEB app; the desktop client is cookie-less and
  // always sends a bearer token. Previously this 401'd before Better Auth was
  // consulted, so a valid session cookie was rejected by construction — which
  // made GET /api/me (the only endpoint exposing the resolved tier) unreachable
  // from a browser, and would have forced apps/web to fork resolveTier().
  if (usingCookie) {
    // A cookie is attached by the browser automatically, so a cross-site POST
    // would otherwise be authenticated — CSRF surface that bearer auth never
    // had. Bearer requests are exempt: an attacker cannot set that header
    // cross-origin without CORS approval.
    const method = c.req.method;
    if (method !== "GET" && method !== "HEAD" && method !== "OPTIONS") {
      const origin = c.req.header("Origin");
      if (!origin || !webOrigins(c.env).includes(origin)) {
        return c.json({ error: "Origin not allowed" }, 403);
      }
    }
  }

  let session: Awaited<ReturnType<ReturnType<typeof getAuth>["api"]["getSession"]>>;
  try {
    // The bearer plugin's before-hook reads `c.headers` on `auth.api.*` calls
    // (not just requests routed through `auth.handler`), so forwarding the raw
    // request headers is what makes the Authorization header resolve here.
    // Both token forms work: the raw `session.token` and the signed
    // `set-auth-token` form. The desktop app ships the raw one.
    session = await getAuth(c.env).api.getSession({ headers: c.req.raw.headers });
  } catch (e) {
    // Never leak adapter/JWT internals to the caller.
    console.error("requireAuth: session lookup failed", e instanceof Error ? e.message : e);
    return c.json({ error: "Authentication failed" }, 401);
  }

  if (!session) {
    return c.json({ error: "Invalid or expired session" }, 401);
  }

  c.set("session", {
    expiresAt: new Date(session.session.expiresAt).toISOString(),
  });

  c.set("user", {
    uid: session.user.id,
    email: session.user.email,
    claims: {
      tester: session.user.tester === true,
      blocked: session.user.blocked === true,
    },
  });

  await next();
});
