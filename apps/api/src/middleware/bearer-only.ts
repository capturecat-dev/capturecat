import { createMiddleware } from "hono/factory";
import type { Env, Variables } from "../types";
import { bearerToken } from "../lib/agent-tokens";

/**
 * Native apps only: 401 unless the request carries `Authorization: Bearer …`,
 * and the session can then ONLY come from that bearer token.
 *
 * For endpoints that hand out device secrets (the account's wireless link
 * key) or drive devices (pushes). A browser cookie session must never reach
 * them: any script running on a trusted web origin (an XSS) could otherwise
 * read the key with `credentials: "include"`.
 *
 * Requiring the header alone is not enough. Better Auth's bearer plugin
 * leaves the request's cookies in place when the bearer value does not verify,
 * so `Authorization: Bearer junk` plus the browser's cookie would still resolve
 * the COOKIE's session in requireAuth. This middleware therefore strips the
 * Cookie header before anything downstream looks at the request.
 *
 * Chain it BEFORE refuseAgentCredentials and requireAuth:
 *   requireBearer, refuseAgentCredentials, requireAuth
 */
export const requireBearer = createMiddleware<{ Bindings: Env; Variables: Variables }>(async (c, next) => {
  if (!bearerToken(c.req.header("Authorization"))) {
    return c.json(
      {
        error: "This endpoint is only for the CaptureCat apps. Sign in to the app and try again.",
        code: "bearer_required",
      },
      401,
    );
  }
  if (c.req.raw.headers.has("Cookie")) {
    const headers = new Headers(c.req.raw.headers);
    headers.delete("Cookie");
    // Nothing has read the body yet, so the new Request takes it over intact.
    c.req.raw = new Request(c.req.raw, { headers });
  }
  await next();
});
